﻿function Invoke-AsCurrentUser {
    <#
    .SYNOPSIS
    Function for running specified code under all logged users (impersonate the currently logged on user).
    Common use case is when code is running under SYSTEM and you need to run something under logged users (to modify user registry etc).

    .DESCRIPTION
    Function for running specified code under all logged users (impersonate the currently logged on user).
    Common use case is when code is running under SYSTEM and you need to run something under logged users (to modify user registry etc).

    You have to run this under SYSTEM account, or ADMIN account (but in such case helper sched. task will be created, content to run will be saved to disk and called from sched. task under SYSTEM account).

    Helper files and sched. tasks are automatically deleted.

    .PARAMETER ScriptBlock
    Scriptblock that should be run under logged users.

    .PARAMETER ComputerName
    Name of computer, where to run this.
    If specified, psremoting will be used to connect, this function with scriptBlock to run will be saved to disk and run through helper scheduled task under SYSTEM account.

    .PARAMETER ReturnTranscript
    Return output of the scriptBlock being run.

    .PARAMETER NoWait
    Don't wait for scriptBlock code finish.

    .PARAMETER UseWindowsPowerShell
    Use default PowerShell exe instead of of the one, this was launched under.

    .PARAMETER NonElevatedSession
    Run non elevated.

    .PARAMETER Visible
    Parameter description

    .PARAMETER CacheToDisk
    Necessity for long scriptBlocks. Content will be saved to disk and run from there.

    .PARAMETER Argument
    If you need to pass some variables to the scriptBlock.
    Hashtable where keys will be names of variables and values will be, well values :)

    Example:
    [hashtable]$Argument = @{
        name = "John"
        cities = "Boston", "Prague"
        hash = @{var1 = 'value1','value11'; var2 = @{ key ='value' }}
    }

    Will in beginning of the scriptBlock define variables:
    $name = 'John'
    $cities = 'Boston', 'Prague'
    $hash = @{var1 = 'value1','value11'; var2 = @{ key ='value' }

    ! ONLY STRING, ARRAY and HASHTABLE variables are supported !

    .EXAMPLE
    Invoke-AsCurrentUser {New-Item C:\temp\$env:username}

    On local computer will call given scriptblock under all logged users.

    .EXAMPLE
    Invoke-AsCurrentUser {New-Item "$env:USERPROFILE\$name"} -computerName PC-01 -ReturnTranscript -Argument @{name = 'someFolder'} -Verbose

    On computer PC-01 will call given scriptblock under all logged users i.e. will create folder 'someFolder' in root of each user profile.
    Transcript of the run scriptBlock will be outputted in console too.

    .NOTES
    Based on https://github.com/KelvinTegelaar/RunAsUser
    #>

    [Alias("Invoke-AsLoggedUser")]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,
        [Parameter(Mandatory = $false)]
        [string] $ComputerName,
        [Parameter(Mandatory = $false)]
        [switch] $ReturnTranscript,
        [Parameter(Mandatory = $false)]
        [switch]$NoWait,
        [Parameter(Mandatory = $false)]
        [switch]$UseWindowsPowerShell,
        [Parameter(Mandatory = $false)]
        [switch]$NonElevatedSession,
        [Parameter(Mandatory = $false)]
        [switch]$Visible,
        [Parameter(Mandatory = $false)]
        [switch]$CacheToDisk,
        [Parameter(Mandatory = $false)]
        [hashtable]$Argument
    )

    if ($ReturnTranscript -and $NoWait) {
        throw "It is not possible to return transcript if you don't want to wait for code finish"
    }

    #region variables
    $TranscriptPath = "C:\78943728TEMP63287789\Invoke-AsCurrentUser.log"
    #endregion variables

    #region functions
    function Create-VariableTextDefinition {
        <#
        .SYNOPSIS
        Function will convert hashtable content to text definition of variables, where hash key is name of variable and hash value is therefore value of this new variable.

        .PARAMETER hashTable
        HashTable which content will be transformed to variables

        .PARAMETER returnHashItself
        Returns text representation of hashTable parameter value itself.

        .EXAMPLE
        [hashtable]$Argument = @{
            string = "jmeno"
            array = "neco", "necojineho"
            hash = @{var1 = 'value1','value11'; var2 = @{ key ='value' }}
        }

        Create-VariableTextDefinition $Argument
    #>

        [CmdletBinding()]
        [Parameter(Mandatory = $true)]
        param (
            [hashtable] $hashTable
            ,
            [switch] $returnHashItself
        )

        function _convertToStringRepresentation {
            param ($object)

            $type = $object.gettype()
            if (($type.Name -eq 'Object[]' -and $type.BaseType.Name -eq 'Array') -or ($type.Name -eq 'ArrayList')) {
                Write-Verbose "array"
                ($object | % {
                        _convertToStringRepresentation $_
                    }) -join ", "
            } elseif ($type.Name -eq 'HashTable' -and $type.BaseType.Name -eq 'Object') {
                Write-Verbose "hash"
                $hashContent = $object.getenumerator() | % {
                    '{0} = {1};' -f $_.key, (_convertToStringRepresentation $_.value)
                }
                "@{$hashContent}"
            } elseif ($type.Name -eq 'String') {
                Write-Verbose "string"
                "'$object'"
            } else {
                throw "undefined type"
            }
        }
        if ($returnHashItself) {
            _convertToStringRepresentation $hashTable
        } else {
            $hashTable.GetEnumerator() | % {
                $variableName = $_.Key
                $variableValue = _convertToStringRepresentation $_.value
                "`$$variableName = $variableValue"
            }
        }
    }

    function Get-LoggedOnUser {
        quser | Select-Object -Skip 1 | ForEach-Object {
            $CurrentLine = $_.Trim() -Replace '\s+', ' ' -Split '\s'
            $HashProps = @{
                UserName     = $CurrentLine[0]
                ComputerName = $env:COMPUTERNAME
            }

            # If session is disconnected different fields will be selected
            if ($CurrentLine[2] -eq 'Disc') {
                $HashProps.SessionName = $null
                $HashProps.Id = $CurrentLine[1]
                $HashProps.State = $CurrentLine[2]
                $HashProps.IdleTime = $CurrentLine[3]
                $HashProps.LogonTime = $CurrentLine[4..6] -join ' '
            } else {
                $HashProps.SessionName = $CurrentLine[1]
                $HashProps.Id = $CurrentLine[2]
                $HashProps.State = $CurrentLine[3]
                $HashProps.IdleTime = $CurrentLine[4]
                $HashProps.LogonTime = $CurrentLine[5..7] -join ' '
            }

            $obj = New-Object -TypeName PSCustomObject -Property $HashProps | Select-Object -Property UserName, ComputerName, SessionName, Id, State, IdleTime, LogonTime
            #insert a new type name for the object
            $obj.psobject.Typenames.Insert(0, 'My.GetLoggedOnUser')
            $obj
        }
    }

    function _Invoke-AsCurrentUser {
        if (!("RunAsUser.ProcessExtensions" -as [type])) {
            $source = @"
using Microsoft.Win32.SafeHandles;
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace RunAsUser
{
    internal class NativeHelpers
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct PROCESS_INFORMATION
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public int dwProcessId;
            public int dwThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct STARTUPINFO
        {
            public int cb;
            public String lpReserved;
            public String lpDesktop;
            public String lpTitle;
            public uint dwX;
            public uint dwY;
            public uint dwXSize;
            public uint dwYSize;
            public uint dwXCountChars;
            public uint dwYCountChars;
            public uint dwFillAttribute;
            public uint dwFlags;
            public short wShowWindow;
            public short cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct WTS_SESSION_INFO
        {
            public readonly UInt32 SessionID;

            [MarshalAs(UnmanagedType.LPStr)]
            public readonly String pWinStationName;

            public readonly WTS_CONNECTSTATE_CLASS State;
        }
    }

    internal class NativeMethods
    {
        [DllImport("kernel32", SetLastError=true)]
        public static extern int WaitForSingleObject(
          IntPtr hHandle,
          int dwMilliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(
            IntPtr hSnapshot);

        [DllImport("userenv.dll", SetLastError = true)]
        public static extern bool CreateEnvironmentBlock(
            ref IntPtr lpEnvironment,
            SafeHandle hToken,
            bool bInherit);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool CreateProcessAsUserW(
            SafeHandle hToken,
            String lpApplicationName,
            StringBuilder lpCommandLine,
            IntPtr lpProcessAttributes,
            IntPtr lpThreadAttributes,
            bool bInheritHandle,
            uint dwCreationFlags,
            IntPtr lpEnvironment,
            String lpCurrentDirectory,
            ref NativeHelpers.STARTUPINFO lpStartupInfo,
            out NativeHelpers.PROCESS_INFORMATION lpProcessInformation);

        [DllImport("userenv.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool DestroyEnvironmentBlock(
            IntPtr lpEnvironment);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool DuplicateTokenEx(
            SafeHandle ExistingTokenHandle,
            uint dwDesiredAccess,
            IntPtr lpThreadAttributes,
            SECURITY_IMPERSONATION_LEVEL ImpersonationLevel,
            TOKEN_TYPE TokenType,
            out SafeNativeHandle DuplicateTokenHandle);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool GetTokenInformation(
            SafeHandle TokenHandle,
            uint TokenInformationClass,
            SafeMemoryBuffer TokenInformation,
            int TokenInformationLength,
            out int ReturnLength);

        [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool WTSEnumerateSessions(
            IntPtr hServer,
            int Reserved,
            int Version,
            ref IntPtr ppSessionInfo,
            ref int pCount);

        [DllImport("wtsapi32.dll")]
        public static extern void WTSFreeMemory(
            IntPtr pMemory);

        [DllImport("kernel32.dll")]
        public static extern uint WTSGetActiveConsoleSessionId();

        [DllImport("Wtsapi32.dll", SetLastError = true)]
        public static extern bool WTSQueryUserToken(
            uint SessionId,
            out SafeNativeHandle phToken);
    }

    internal class SafeMemoryBuffer : SafeHandleZeroOrMinusOneIsInvalid
    {
        public SafeMemoryBuffer(int cb) : base(true)
        {
            base.SetHandle(Marshal.AllocHGlobal(cb));
        }
        public SafeMemoryBuffer(IntPtr handle) : base(true)
        {
            base.SetHandle(handle);
        }

        protected override bool ReleaseHandle()
        {
            Marshal.FreeHGlobal(handle);
            return true;
        }
    }

    internal class SafeNativeHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        public SafeNativeHandle() : base(true) { }
        public SafeNativeHandle(IntPtr handle) : base(true) { this.handle = handle; }

        protected override bool ReleaseHandle()
        {
            return NativeMethods.CloseHandle(handle);
        }
    }

    internal enum SECURITY_IMPERSONATION_LEVEL
    {
        SecurityAnonymous = 0,
        SecurityIdentification = 1,
        SecurityImpersonation = 2,
        SecurityDelegation = 3,
    }

    internal enum SW
    {
        SW_HIDE = 0,
        SW_SHOWNORMAL = 1,
        SW_NORMAL = 1,
        SW_SHOWMINIMIZED = 2,
        SW_SHOWMAXIMIZED = 3,
        SW_MAXIMIZE = 3,
        SW_SHOWNOACTIVATE = 4,
        SW_SHOW = 5,
        SW_MINIMIZE = 6,
        SW_SHOWMINNOACTIVE = 7,
        SW_SHOWNA = 8,
        SW_RESTORE = 9,
        SW_SHOWDEFAULT = 10,
        SW_MAX = 10
    }

    internal enum TokenElevationType
    {
        TokenElevationTypeDefault = 1,
        TokenElevationTypeFull,
        TokenElevationTypeLimited,
    }

    internal enum TOKEN_TYPE
    {
        TokenPrimary = 1,
        TokenImpersonation = 2
    }

    internal enum WTS_CONNECTSTATE_CLASS
    {
        WTSActive,
        WTSConnected,
        WTSConnectQuery,
        WTSShadow,
        WTSDisconnected,
        WTSIdle,
        WTSListen,
        WTSReset,
        WTSDown,
        WTSInit
    }

    public class Win32Exception : System.ComponentModel.Win32Exception
    {
        private string _msg;

        public Win32Exception(string message) : this(Marshal.GetLastWin32Error(), message) { }
        public Win32Exception(int errorCode, string message) : base(errorCode)
        {
            _msg = String.Format("{0} ({1}, Win32ErrorCode {2} - 0x{2:X8})", message, base.Message, errorCode);
        }

        public override string Message { get { return _msg; } }
        public static explicit operator Win32Exception(string message) { return new Win32Exception(message); }
    }

    public static class ProcessExtensions
    {
        #region Win32 Constants

        private const int CREATE_UNICODE_ENVIRONMENT = 0x00000400;
        private const int CREATE_NO_WINDOW = 0x08000000;

        private const int CREATE_NEW_CONSOLE = 0x00000010;

        private const uint INVALID_SESSION_ID = 0xFFFFFFFF;
        private static readonly IntPtr WTS_CURRENT_SERVER_HANDLE = IntPtr.Zero;

        #endregion

        // Gets the user token from the currently active session
        private static SafeNativeHandle GetSessionUserToken(bool elevated)
        {
            var activeSessionId = INVALID_SESSION_ID;
            var pSessionInfo = IntPtr.Zero;
            var sessionCount = 0;

            // Get a handle to the user access token for the current active session.
            if (NativeMethods.WTSEnumerateSessions(WTS_CURRENT_SERVER_HANDLE, 0, 1, ref pSessionInfo, ref sessionCount))
            {
                try
                {
                    var arrayElementSize = Marshal.SizeOf(typeof(NativeHelpers.WTS_SESSION_INFO));
                    var current = pSessionInfo;

                    for (var i = 0; i < sessionCount; i++)
                    {
                        var si = (NativeHelpers.WTS_SESSION_INFO)Marshal.PtrToStructure(
                            current, typeof(NativeHelpers.WTS_SESSION_INFO));
                        current = IntPtr.Add(current, arrayElementSize);

                        if (si.State == WTS_CONNECTSTATE_CLASS.WTSActive)
                        {
                            activeSessionId = si.SessionID;
                            break;
                        }
                    }
                }
                finally
                {
                    NativeMethods.WTSFreeMemory(pSessionInfo);
                }
            }

            // If enumerating did not work, fall back to the old method
            if (activeSessionId == INVALID_SESSION_ID)
            {
                activeSessionId = NativeMethods.WTSGetActiveConsoleSessionId();
            }

            SafeNativeHandle hImpersonationToken;
            if (!NativeMethods.WTSQueryUserToken(activeSessionId, out hImpersonationToken))
            {
                throw new Win32Exception("WTSQueryUserToken failed to get access token.");
            }

            using (hImpersonationToken)
            {
                // First see if the token is the full token or not. If it is a limited token we need to get the
                // linked (full/elevated token) and use that for the CreateProcess task. If it is already the full or
                // default token then we already have the best token possible.
                TokenElevationType elevationType = GetTokenElevationType(hImpersonationToken);

                if (elevationType == TokenElevationType.TokenElevationTypeLimited && elevated == true)
                {
                    using (var linkedToken = GetTokenLinkedToken(hImpersonationToken))
                        return DuplicateTokenAsPrimary(linkedToken);
                }
                else
                {
                    return DuplicateTokenAsPrimary(hImpersonationToken);
                }
            }
        }

        public static int StartProcessAsCurrentUser(string appPath, string cmdLine = null, string workDir = null, bool visible = true,int wait = -1, bool elevated = true)
        {
            using (var hUserToken = GetSessionUserToken(elevated))
            {
                var startInfo = new NativeHelpers.STARTUPINFO();
                startInfo.cb = Marshal.SizeOf(startInfo);

                uint dwCreationFlags = CREATE_UNICODE_ENVIRONMENT | (uint)(visible ? CREATE_NEW_CONSOLE : CREATE_NO_WINDOW);
                startInfo.wShowWindow = (short)(visible ? SW.SW_SHOW : SW.SW_HIDE);
                //startInfo.lpDesktop = "winsta0\\default";

                IntPtr pEnv = IntPtr.Zero;
                if (!NativeMethods.CreateEnvironmentBlock(ref pEnv, hUserToken, false))
                {
                    throw new Win32Exception("CreateEnvironmentBlock failed.");
                }
                try
                {
                    StringBuilder commandLine = new StringBuilder(cmdLine);
                    var procInfo = new NativeHelpers.PROCESS_INFORMATION();

                    if (!NativeMethods.CreateProcessAsUserW(hUserToken,
                        appPath, // Application Name
                        commandLine, // Command Line
                        IntPtr.Zero,
                        IntPtr.Zero,
                        false,
                        dwCreationFlags,
                        pEnv,
                        workDir, // Working directory
                        ref startInfo,
                        out procInfo))
                    {
                        throw new Win32Exception("CreateProcessAsUser failed.");
                    }

                    try
                    {
                        NativeMethods.WaitForSingleObject( procInfo.hProcess, wait);
                        return procInfo.dwProcessId;
                    }
                    finally
                    {
                        NativeMethods.CloseHandle(procInfo.hThread);
                        NativeMethods.CloseHandle(procInfo.hProcess);
                    }
                }
                finally
                {
                    NativeMethods.DestroyEnvironmentBlock(pEnv);
                }
            }
        }

        private static SafeNativeHandle DuplicateTokenAsPrimary(SafeHandle hToken)
        {
            SafeNativeHandle pDupToken;
            if (!NativeMethods.DuplicateTokenEx(hToken, 0, IntPtr.Zero, SECURITY_IMPERSONATION_LEVEL.SecurityImpersonation,
                TOKEN_TYPE.TokenPrimary, out pDupToken))
            {
                throw new Win32Exception("DuplicateTokenEx failed.");
            }

            return pDupToken;
        }

        private static TokenElevationType GetTokenElevationType(SafeHandle hToken)
        {
            using (SafeMemoryBuffer tokenInfo = GetTokenInformation(hToken, 18))
            {
                return (TokenElevationType)Marshal.ReadInt32(tokenInfo.DangerousGetHandle());
            }
        }

        private static SafeNativeHandle GetTokenLinkedToken(SafeHandle hToken)
        {
            using (SafeMemoryBuffer tokenInfo = GetTokenInformation(hToken, 19))
            {
                return new SafeNativeHandle(Marshal.ReadIntPtr(tokenInfo.DangerousGetHandle()));
            }
        }

        private static SafeMemoryBuffer GetTokenInformation(SafeHandle hToken, uint infoClass)
        {
            int returnLength;
            bool res = NativeMethods.GetTokenInformation(hToken, infoClass, new SafeMemoryBuffer(IntPtr.Zero), 0,
                out returnLength);
            int errCode = Marshal.GetLastWin32Error();
            if (!res && errCode != 24 && errCode != 122)  // ERROR_INSUFFICIENT_BUFFER, ERROR_BAD_LENGTH
            {
                throw new Win32Exception(errCode, String.Format("GetTokenInformation({0}) failed to get buffer length", infoClass));
            }

            SafeMemoryBuffer tokenInfo = new SafeMemoryBuffer(returnLength);
            if (!NativeMethods.GetTokenInformation(hToken, infoClass, tokenInfo, returnLength, out returnLength))
                throw new Win32Exception(String.Format("GetTokenInformation({0}) failed", infoClass));

            return tokenInfo;
        }
    }
}
"@
            Add-Type -TypeDefinition $source -Language CSharp
        }
        if ($CacheToDisk) {
            $ScriptGuid = New-Guid
            $null = New-Item "$($ENV:TEMP)\$($ScriptGuid).ps1" -Value $ScriptBlock -Force
            $pwshcommand = "-ExecutionPolicy Bypass -Window Normal -file `"$($ENV:TEMP)\$($ScriptGuid).ps1`""
        } else {
            $encodedcommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($ScriptBlock))
            $pwshcommand = "-ExecutionPolicy Bypass -Window Normal -EncodedCommand $($encodedcommand)"
        }
        $OSLevel = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentVersion
        if ($OSLevel -lt 6.2) { $MaxLength = 8190 } else { $MaxLength = 32767 }
        if ($encodedcommand.length -gt $MaxLength -and $CacheToDisk -eq $false) {
            Write-Error -Message "The encoded script is longer than the command line parameter limit. Please execute the script with the -CacheToDisk option."
            return
        }
        $privs = whoami /priv /fo csv | ConvertFrom-Csv | Where-Object { $_.'Privilege Name' -eq 'SeDelegateSessionUserImpersonatePrivilege' }
        if ($privs.State -eq "Disabled") {
            Write-Error -Message "Not running with correct privilege. You must run this script as system or have the SeDelegateSessionUserImpersonatePrivilege token."
            return
        } else {
            try {
                # Use the same PowerShell executable as the one that invoked the function, Unless -UseWindowsPowerShell is defined

                if (!$UseWindowsPowerShell) { $pwshPath = (Get-Process -Id $pid).Path } else { $pwshPath = "$($ENV:windir)\system32\WindowsPowerShell\v1.0\powershell.exe" }
                if ($NoWait) { $ProcWaitTime = 1 } else { $ProcWaitTime = -1 }
                if ($NonElevatedSession) { $RunAsAdmin = $false } else { $RunAsAdmin = $true }
                [RunAsUser.ProcessExtensions]::StartProcessAsCurrentUser(
                    $pwshPath, "`"$pwshPath`" $pwshcommand", (Split-Path $pwshPath -Parent), $Visible, $ProcWaitTime, $RunAsAdmin)
                if ($CacheToDisk) { $null = Remove-Item "$($ENV:TEMP)\$($ScriptGuid).ps1" -Force }
            } catch {
                Write-Error -Message "Could not execute as currently logged on user: $($_.Exception.Message)" -Exception $_.Exception
                return
            }
        }
    }
    #endregion functions

    #region prepare Invoke-Command parameters
    # export this function to remote session (so I am not dependant whether it exists there or not)
    $allFunctionDefs = "function Invoke-AsCurrentUser { ${function:Invoke-AsCurrentUser} }; function Create-VariableTextDefinition { ${function:Create-VariableTextDefinition} }; function Get-LoggedOnUser { ${function:Get-LoggedOnUser} }"

    $param = @{
        argumentList = $scriptBlock, $NoWait, $UseWindowsPowerShell, $NonElevatedSession, $Visible, $CacheToDisk, $allFunctionDefs, $VerbosePreference, $ReturnTranscript, $Argument
    }

    if ($computerName -and $computerName -notmatch "localhost|$env:COMPUTERNAME") {
        $param.computerName = $computerName
    }
    #endregion prepare Invoke-Command parameters

    #region rights checks
    $hasAdminRights = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
    $hasSystemRights = whoami /priv /fo csv | ConvertFrom-Csv | Where-Object { $_.'Privilege Name' -eq 'SeDelegateSessionUserImpersonatePrivilege' -and $_.State -eq "Enabled" }
    #HACK in remote session this detection incorrectly shows that I have rights, but than function will fail anyway
    if ((Get-Host).name -eq "ServerRemoteHost") { $hasSystemRights = $false }
    Write-Verbose "ADMIN: $hasAdminRights SYSTEM: $hasSystemRights"
    #endregion rights checks

    if ($param.computerName) {
        Write-Verbose "Will be run on remote computer $computerName"

        Invoke-Command @param -ScriptBlock {
            param ($scriptBlock, $NoWait, $UseWindowsPowerShell, $NonElevatedSession, $Visible, $CacheToDisk, $allFunctionDefs, $VerbosePreference, $ReturnTranscript, $Argument)

            foreach ($functionDef in $allFunctionDefs) {
                . ([ScriptBlock]::Create($functionDef))
            }

            # check that there is someone logged
            if ((Get-LoggedOnUser).state -notcontains "Active") {
                Write-Warning "On $env:COMPUTERNAME is no user logged in"
                return
            }

            # convert passed string back to scriptblock
            $scriptBlock = [Scriptblock]::Create($scriptBlock)

            $param = @{scriptBlock = $scriptBlock }
            if ($VerbosePreference -eq "Continue") { $param.verbose = $true }
            if ($NoWait) { $param.NoWait = $NoWait }
            if ($UseWindowsPowerShell) { $param.UseWindowsPowerShell = $UseWindowsPowerShell }
            if ($NonElevatedSession) { $param.NonElevatedSession = $NonElevatedSession }
            if ($Visible) { $param.Visible = $Visible }
            if ($CacheToDisk) { $param.CacheToDisk = $CacheToDisk }
            if ($ReturnTranscript) { $param.ReturnTranscript = $ReturnTranscript }
            if ($Argument) { $param.Argument = $Argument }

            # run again "locally" on remote computer
            Invoke-AsCurrentUser @param
        }
    } elseif (!$ComputerName -and !$hasSystemRights -and $hasAdminRights) {
        # create helper sched. task, that will under SYSTEM account run given scriptblock using Invoke-AsCurrentUser
        Write-Verbose "Running locally as ADMIN"

        # create helper script, that will be called from sched. task under SYSTEM account
        if ($VerbosePreference -eq "Continue") { $VerboseParam = "-Verbose" }
        if ($ReturnTranscript) { $ReturnTranscriptParam = "-ReturnTranscript" }
        if ($NoWait) { $NoWaitParam = "-NoWait" }
        if ($UseWindowsPowerShell) { $UseWindowsPowerShellParam = "-UseWindowsPowerShell" }
        if ($NonElevatedSession) { $NonElevatedSessionParam = "-NonElevatedSession" }
        if ($Visible) { $VisibleParam = "-Visible" }
        if ($CacheToDisk) { $CacheToDiskParam = "-CacheToDisk" }
        if ($Argument) {
            $ArgumentHashText = Create-VariableTextDefinition $Argument -returnHashItself
            $ArgumentParam = "-Argument $ArgumentHashText"
        }

        $helperScriptText = @"
# define function Invoke-AsCurrentUser
$allFunctionDefs

`$scriptBlockText = @'
$($ScriptBlock.ToString())
'@

# transform string to scriptblock
`$scriptBlock = [Scriptblock]::Create(`$scriptBlockText)

# run scriptblock under all local logged users
Invoke-AsCurrentUser -ScriptBlock `$scriptblock $VerboseParam $ReturnTranscriptParam $NoWaitParam $UseWindowsPowerShellParam $NonElevatedSessionParam $VisibleParam $CacheToDiskParam $ArgumentParam
"@

        Write-Verbose "####### HELPER SCRIPT TEXT"
        Write-Verbose $helperScriptText
        Write-Verbose "####### END"

        $tmpScript = "$env:windir\Temp\$(Get-Random).ps1"
        Write-Verbose "Creating helper script $tmpScript"
        $helperScriptText | Out-File -FilePath $tmpScript -Force -Encoding utf8

        # create helper sched. task
        $taskName = "RunAsUser_" + (Get-Random)
        Write-Verbose "Creating helper scheduled task $taskName"
        $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -DontStopOnIdleEnd
        $taskAction = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-NoProfile -NoLogo -NonInteractive -ExecutionPolicy Bypass -File `"$tmpScript`""
        Register-ScheduledTask -TaskName $taskName -User "NT AUTHORITY\SYSTEM" -Action $taskAction -RunLevel Highest -Settings $taskSettings -Force | Out-Null

        # start helper sched. task
        Write-Verbose "Starting helper scheduled task $taskName"
        Start-ScheduledTask $taskName

        # wait for helper sched. task finish
        while ((Get-ScheduledTask $taskName -ErrorAction silentlyContinue).state -ne "Ready") {
            Write-Warning "Waiting for task $taskName to finish"
            Start-Sleep -Milliseconds 200
        }
        if (($lastTaskResult = (Get-ScheduledTaskInfo $taskName).lastTaskResult) -ne 0) {
            Write-Error "Task failed with error $lastTaskResult"
        }

        # delete helper sched. task
        Write-Verbose "Removing helper scheduled task $taskName"
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false

        # delete helper script
        Write-Verbose "Removing helper script $tmpScript"
        Remove-Item $tmpScript -Force

        # read & delete transcript
        if ($ReturnTranscript) {
            # return just interesting part of transcript
            if (Test-Path $TranscriptPath) {
                ((Get-Content $TranscriptPath -Raw) -Split [regex]::escape('**********************'))[2]
                Remove-Item (Split-Path $TranscriptPath -Parent) -Recurse -Force
            } else {
                Write-Warning "There is no transcript, command probably failed!"
            }
        }
    } elseif (!$ComputerName -and !$hasSystemRights -and !$hasAdminRights) {
        throw "Insufficient rights (not ADMIN nor SYSTEM)"
    } elseif (!$ComputerName -and $hasSystemRights) {
        Write-Verbose "Running locally as SYSTEM"

        if ($Argument -or $ReturnTranscript) {
            # define passed variables
            if ($Argument) {
                # convert hash to variables text definition
                $VariableTextDef = Create-VariableTextDefinition $Argument
            }

            if ($ReturnTranscript) {
                # modify scriptBlock to contain creation of transcript
                $TranscriptStart = "Start-Transcript $TranscriptPath -Append" # append because code can run under more than one user at a time
                $TranscriptEnd = 'Stop-Transcript'
            }

            $ScriptBlockContent = ($TranscriptStart + "`n`n" + $VariableTextDef + "`n`n" + $ScriptBlock.ToString() + "`n`n" + $TranscriptStop)
            Write-Verbose "####### SCRIPTBLOCK TO RUN"
            Write-Verbose $ScriptBlockContent
            Write-Verbose "#######"
            $scriptBlock = [Scriptblock]::Create($ScriptBlockContent)
        }

        _Invoke-AsCurrentUser
    } else {
        throw "undefined"
    }
}
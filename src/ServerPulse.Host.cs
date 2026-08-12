using System;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("Server Pulse")]
[assembly: AssemblyDescription("SSH server resource monitor")]
[assembly: AssemblyCompany("Server Pulse")]
[assembly: AssemblyProduct("Server Pulse")]
[assembly: AssemblyCopyright("Copyright © Server Pulse")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

internal static class ServerPulseHost
{
    private const string AppUserModelId = "Public.ServerPulse.Desktop";
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    private const int JobObjectExtendedLimitInformation = 9;
    private static IntPtr jobHandle = IntPtr.Zero;

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateJobObject(IntPtr securityAttributes, string name);

    [DllImport("kernel32.dll")]
    private static extern bool SetInformationJobObject(IntPtr job, int informationClass, IntPtr information, uint informationLength);

    [DllImport("kernel32.dll")]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    private static void CreateProcessJob()
    {
        jobHandle = CreateJobObject(IntPtr.Zero, null);
        if (jobHandle == IntPtr.Zero) return;

        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        int length = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
        IntPtr buffer = Marshal.AllocHGlobal(length);
        try
        {
            Marshal.StructureToPtr(limits, buffer, false);
            if (!SetInformationJobObject(jobHandle, JobObjectExtendedLimitInformation, buffer, (uint)length) ||
                !AssignProcessToJobObject(jobHandle, GetCurrentProcess()))
            {
                CloseHandle(jobHandle);
                jobHandle = IntPtr.Zero;
            }
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    private static int RunPowerShell(string scriptPath, bool smokeTest)
    {
        InitialSessionState initialState = InitialSessionState.CreateDefault();
        initialState.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
        using (Runspace runspace = RunspaceFactory.CreateRunspace(initialState))
        {
            runspace.ApartmentState = ApartmentState.STA;
            runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
            runspace.Open();
            using (PowerShell powerShell = PowerShell.Create())
            {
                powerShell.Runspace = runspace;
                powerShell.AddCommand(scriptPath);
                if (smokeTest) powerShell.AddParameter("SmokeTest");
                Collection<PSObject> output = powerShell.Invoke();
                if (smokeTest)
                {
                    foreach (PSObject item in output) Console.Out.WriteLine(item == null ? String.Empty : item.ToString());
                }
                if (powerShell.HadErrors)
                {
                    string message = powerShell.Streams.Error.Count == 0 ? "PowerShell 启动失败" : powerShell.Streams.Error[0].ToString();
                    throw new InvalidOperationException(message);
                }
            }
        }
        return 0;
    }

    [STAThread]
    private static int Main(string[] args)
    {
        bool smokeTest = Array.Exists(args, delegate(string value) { return String.Equals(value, "--smoke-test", StringComparison.OrdinalIgnoreCase); });
        string root = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string scriptPath = Path.Combine(root, "ServerPulse.ps1");
        if (!File.Exists(scriptPath))
        {
            MessageBox.Show("找不到 ServerPulse.ps1：\n" + scriptPath, "Server Pulse", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }

        SetCurrentProcessExplicitAppUserModelID(AppUserModelId);
        Environment.SetEnvironmentVariable("SERVERPULSE_APP_USER_MODEL_ID", AppUserModelId);
        Directory.SetCurrentDirectory(root);
        CreateProcessJob();
        try
        {
            return RunPowerShell(scriptPath, smokeTest);
        }
        catch (Exception exception)
        {
            if (smokeTest) Console.Error.WriteLine(exception.ToString());
            else MessageBox.Show(exception.Message, "Server Pulse 启动失败", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        finally
        {
            if (jobHandle != IntPtr.Zero)
            {
                CloseHandle(jobHandle);
                jobHandle = IntPtr.Zero;
            }
        }
    }
}

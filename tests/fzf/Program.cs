using System.Text;

if (args.SequenceEqual(["--version"])) { Console.WriteLine("test harness"); return; }
if (!args.SequenceEqual(["--read0", "--print0"])) { Environment.ExitCode = 2; return; }
using var input = Console.OpenStandardInput();
using var data = new MemoryStream();
input.CopyTo(data);
var bytes = data.ToArray();
var end = Array.IndexOf(bytes, (byte)0);
if (end < 0) { Environment.ExitCode = 3; return; }
using var output = Console.OpenStandardOutput();
output.Write(bytes.AsSpan(0, end + 1));

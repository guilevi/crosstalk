// cscript shortcut.js <link path> <target> <description>
// Creates (or, with "-" as target, deletes) a Start Menu shortcut, which
// CrossOver lists as a launcher for the bottle.
var a = WScript.Arguments;
var fso = WScript.CreateObject("Scripting.FileSystemObject");
if (a(1) == "-") {
	if (fso.FileExists(a(0))) fso.DeleteFile(a(0));
} else {
	var dir = fso.GetParentFolderName(a(0));
	if (!fso.FolderExists(dir)) fso.CreateFolder(dir);
	var s = WScript.CreateObject("WScript.Shell").CreateShortcut(a(0));
	s.TargetPath = a(1);
	s.Description = a(2);
	s.Save();
}

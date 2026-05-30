# Dump RTTI class names, all functions, and weapon-related strings.
# Ghidra Python (Jython 2.7)
from ghidra.program.util import DefinedDataIterator

out_path = "E:\\projects\\TMEMultiplayerClient\\ghidra_dump.txt"
w = open(out_path, "w")

w.write("=== RTTI CLASSES (symbols matching .?AV/.?AU or with RTTI/TypeDescriptor) ===\n")
st = currentProgram.getSymbolTable()
class_count = 0
for s in st.getAllSymbols(True):
    n = s.getName()
    if ("TypeDescriptor" in n or "RTTI" in n or n.startswith(".?AV") or n.startswith(".?AU")):
        w.write("%s @ %s\n" % (n, s.getAddress()))
        class_count += 1
        if class_count > 1000:
            w.write("... truncated\n")
            break
w.write("Total RTTI-ish symbols: %d\n" % class_count)

w.write("\n=== FUNCTIONS ===\n")
fm = currentProgram.getFunctionManager()
fc = 0
for f in fm.getFunctions(True):
    w.write("0x%08x %s\n" % (f.getEntryPoint().getOffset(), f.getName()))
    fc += 1
w.write("Total functions: %d\n" % fc)

w.write("\n=== INTERESTING STRINGS ===\n")
keywords = ["bullet","shoot","damage","pystol","weapon","createbullet","sethealth","takedamage","playershoot","fire","attack","hit"]
for d in DefinedDataIterator.definedStrings(currentProgram):
    v = d.getValue()
    if v is None:
        continue
    s = str(v)
    low = s.lower()
    for k in keywords:
        if k in low:
            w.write("0x%08x \"%s\"\n" % (d.getAddress().getOffset(), s.replace("\n","\\n").replace("\r","\\r")))
            break

w.close()
print("WROTE: " + out_path)

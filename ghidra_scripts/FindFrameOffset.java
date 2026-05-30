import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.data.StringDataInstance;
import ghidra.program.model.symbol.Reference;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.HashSet;
import java.util.Set;

public class FindFrameOffset extends GhidraScript {
    PrintWriter w;
    DecompInterface decomp;

    void dumpCallers(String label, long strAddr) throws Exception {
        w.println("\n========== XREFS TO \"" + label + "\" @ 0x" + Long.toHexString(strAddr) + " ==========");
        Set<Long> callers = new HashSet<>();
        for (Reference r : currentProgram.getReferenceManager().getReferencesTo(toAddr(strAddr))) {
            Function f = getFunctionContaining(r.getFromAddress());
            if (f != null) callers.add(f.getEntryPoint().getOffset());
            w.println("  from 0x" + Long.toHexString(r.getFromAddress().getOffset())
                + " in " + (f != null ? f.getName() : "<none>"));
        }
        // The string is the lua_setglobal/setfield name; the cclosure registered
        // just before it is the binding. We decompile the registrar to find which
        // FUN_ is the GetFrame/SetFrame C function, then decompile that.
    }

    void d(long a, String tag) throws Exception {
        Function f = getFunctionAt(toAddr(a));
        if (f == null) f = createFunction(toAddr(a), null);
        if (f == null) { w.println("[no fn 0x"+Long.toHexString(a)+"]"); return; }
        w.println("\n--- " + tag + " " + f.getName() + " @ 0x" + Long.toHexString(a) + " ---");
        DecompileResults res = decomp.decompileFunction(f, 60, monitor);
        if (res.decompileCompleted() && res.getDecompiledFunction()!=null) w.println(res.getDecompiledFunction().getC());
        else w.println("[decomp failed]");
    }

    @Override public void run() throws Exception {
        w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_frame.txt"));
        decomp = new DecompInterface();
        decomp.openProgram(currentProgram);

        // Find the "GetFrame" and "SetFrame" strings, then their xrefs (registrar),
        // then the registered C functions.
        DataIterator dit = currentProgram.getListing().getDefinedData(true);
        long getFrameStr = 0, setFrameStr = 0, getActionStr = 0;
        while (dit.hasNext()) {
            Data dt = dit.next();
            StringDataInstance sdi = StringDataInstance.getStringDataInstance(dt);
            if (sdi == null || sdi == StringDataInstance.NULL_INSTANCE) continue;
            String s = sdi.getStringValue();
            if (s == null) continue;
            if (s.equals("GetFrame")) getFrameStr = dt.getAddress().getOffset();
            else if (s.equals("SetFrame")) setFrameStr = dt.getAddress().getOffset();
            else if (s.equals("GetAction")) getActionStr = dt.getAddress().getOffset();
        }
        w.println("GetFrame str @ 0x" + Long.toHexString(getFrameStr));
        w.println("SetFrame str @ 0x" + Long.toHexString(setFrameStr));
        w.println("GetAction str @ 0x" + Long.toHexString(getActionStr));

        // Decompile the registrar function(s) that reference these strings —
        // the lua_pushcclosure right before the setglobal names the C function.
        if (getFrameStr != 0) {
            for (Reference r : currentProgram.getReferenceManager().getReferencesTo(toAddr(getFrameStr))) {
                Function f = getFunctionContaining(r.getFromAddress());
                if (f != null) { d(f.getEntryPoint().getOffset(), "registrar-of-GetFrame"); break; }
            }
        }
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_frame.txt");
    }
}

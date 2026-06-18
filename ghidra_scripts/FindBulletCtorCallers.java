import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceManager;
import ghidra.program.model.symbol.ReferenceIterator;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.LinkedHashMap;
import java.util.Map;

// For each subclass ctor, find every call site + decompile the immediate
// caller. The native weapon-shoot path does operator_new(SIZE) then calls
// the ctor — we need SIZE for each subclass to do the same in our own
// native bindings.
public class FindBulletCtorCallers extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_bullet_ctor_callers.txt"));
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        Map<Long, String> ctors = new LinkedHashMap<>();
        ctors.put(0x00497040L, "TBullet");
        ctors.put(0x00497660L, "TCannonBullet");
        ctors.put(0x00497140L, "TExplodingBullet");
        ctors.put(0x00497200L, "TNail");
        ctors.put(0x00497cd0L, "TLaser");
        ctors.put(0x00499d70L, "TRailgunRay");
        ctors.put(0x0049a5c0L, "TRocket");
        ctors.put(0x0049aa10L, "TBlueRocket");

        ReferenceManager rm = currentProgram.getReferenceManager();
        for (Map.Entry<Long, String> e : ctors.entrySet()) {
            Address ctorAddr = toAddr(e.getKey());
            w.println("\n=================================================");
            w.println("== " + e.getValue() + " ctor @ 0x" + Long.toHexString(e.getKey()));
            w.println("=================================================");
            ReferenceIterator refs = rm.getReferencesTo(ctorAddr);
            java.util.Set<String> seenFns = new java.util.LinkedHashSet<>();
            while (refs.hasNext()) {
                Reference r = refs.next();
                Function f = getFunctionContaining(r.getFromAddress());
                if (f == null) continue;
                String key = f.getName() + "@0x" + Long.toHexString(f.getEntryPoint().getOffset());
                if (!seenFns.add(key)) continue;
                if (seenFns.size() > 4) break;
                w.println("\n--- caller: " + key + " (call site 0x" + Long.toHexString(r.getFromAddress().getOffset()) + ") ---");
                DecompileResults dr = decomp.decompileFunction(f, 60, monitor);
                if (dr != null && dr.getDecompiledFunction() != null) {
                    w.println(dr.getDecompiledFunction().getC());
                } else {
                    w.println("(decomp failed)");
                }
            }
        }
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_bullet_ctor_callers.txt");
    }
}

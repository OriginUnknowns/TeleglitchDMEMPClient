import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import java.io.FileWriter;
import java.io.PrintWriter;

/** Trace the damage-tally call chain. FUN_00417720 is the iterator that
 *  AVs on a poisoned attacker-list entry. We want:
 *    1. Its callers (what triggers the tally)
 *    2. The functions that POPULATE the attacker list (so we can hook
 *       them and track every entry's origin)
 *    3. The helpers it uses for iteration (so we know the list shape) */
public class DecompTallyCallers extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_tally_callers.txt"));
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);

        // 1) decompile FUN_00417720 (the tally itself) + its iterator helpers
        long[] core = { 0x00417720L, 0x004372fcL,
                        0x00412ff0L, 0x00408360L,    // get begin / end iterators
                        0x00413650L, 0x00413680L };  // current / advance
        String[] coreNames = { "Tally_417720", "caller_4372fc",
                               "iter_begin_412ff0", "iter_end_408360",
                               "iter_get_413650", "iter_next_413680" };
        for (int i = 0; i < core.length; i++) {
            Address a = toAddr(core[i]);
            Function f = getFunctionContaining(a);
            if (f == null) { try { f = createFunction(a, coreNames[i]); } catch (Exception e) {} }
            if (f == null) { w.println("\n=== " + coreNames[i] + " — NO FN @ 0x" + Long.toHexString(core[i]) + " ==="); continue; }
            w.println("\n=== " + coreNames[i] + " (" + f.getName() + " @ " + f.getEntryPoint() + ") ===");
            try {
                DecompileResults dr = decomp.decompileFunction(f, 60, monitor);
                if (dr != null && dr.getDecompiledFunction() != null) {
                    w.println(dr.getDecompiledFunction().getC());
                }
            } catch (Exception e) { w.println("  err: " + e.getMessage()); }
        }

        // 2) list all xrefs TO FUN_00417720 — these are callers
        w.println("\n\n== xrefs TO FUN_00417720 ==");
        Address tally = toAddr(0x00417720L);
        ReferenceIterator rit = currentProgram.getReferenceManager().getReferencesTo(tally);
        while (rit.hasNext()) {
            Reference r = rit.next();
            Address from = r.getFromAddress();
            Function f = getFunctionContaining(from);
            String info = (f != null) ? (f.getName() + " @ " + f.getEntryPoint()) : "<no fn>";
            w.println("  " + from + " in " + info);
        }

        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_tally_callers.txt");
    }
}

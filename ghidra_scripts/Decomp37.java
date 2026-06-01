import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.*;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;

public class Decomp37 extends GhidraScript {
    @Override
    public void run() throws Exception {
        DecompInterface d = new DecompInterface();
        d.openProgram(currentProgram);
        long[] addrs = { 0x0044f9c0L, 0x0044ec10L, 0x00454c80L };
        String[] names = { "TActor::vt[37]", "TNewLiving::vt[37]", "TEnemy::vt[37]" };
        for (int i = 0; i < addrs.length; i++) {
            Function f = getFunctionAt(toAddr(addrs[i]));
            if (f == null) { println(names[i] + ": no function"); continue; }
            DecompileResults r = d.decompileFunction(f, 30, monitor);
            DecompiledFunction df = r.getDecompiledFunction();
            println("==== " + names[i] + " @ 0x" + Long.toHexString(addrs[i]) + " ====");
            println(df.getC());
            // Also list referrers (who calls it)
            println("---- referrers ----");
            int n = 0;
            for (var ref : currentProgram.getReferenceManager().getReferencesTo(toAddr(addrs[i]))) {
                Function caller = getFunctionContaining(ref.getFromAddress());
                println("  from " + ref.getFromAddress() + " in " + (caller != null ? caller.getName() : "?"));
                if (++n > 8) break;
            }
        }
    }
}

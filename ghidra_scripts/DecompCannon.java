import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolIterator;
import java.io.FileWriter;
import java.io.PrintWriter;

/** Decompile TCannonBullet ctor + per-tick + impact (vt[20]) to plan
 *  replication. The firer-side AV likely lives in vt[20]'s AoE scan
 *  hitting the joiner's TPlayer puppet on the host. */
public class DecompCannon extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_cannon.txt"));
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        Memory mem = currentProgram.getMemory();

        long vt = 0;
        SymbolIterator it = currentProgram.getSymbolTable().getAllSymbols(true);
        while (it.hasNext()) {
            Symbol s = it.next();
            String n = s.getName(true);
            if (n != null && n.contains("TCannonBullet") && n.contains("vftable")) {
                vt = s.getAddress().getOffset();
                w.println("vftable @ 0x" + Long.toHexString(vt) + " (" + n + ")");
                break;
            }
        }

        // Ctor + selected vt slots (per-tick = 11, impact effect = 20)
        long[] addrs = { 0x00497660L };
        String[] names = { "TCannonBullet_ctor_497660" };
        for (int i = 0; i < addrs.length; i++) {
            w.println("\n=== " + names[i] + " @ 0x" + Long.toHexString(addrs[i]) + " ===");
            Function f = getFunctionAt(toAddr(addrs[i]));
            if (f == null) {
                try { f = createFunction(toAddr(addrs[i]), names[i]); }
                catch (Exception e) { w.println("  err: " + e.getMessage()); continue; }
            }
            if (f == null) continue;
            try {
                DecompileResults dr = decomp.decompileFunction(f, 60, monitor);
                if (dr != null && dr.getDecompiledFunction() != null) {
                    w.println(dr.getDecompiledFunction().getC());
                }
            } catch (Exception e) { w.println("  err: " + e.getMessage()); }
        }

        if (vt != 0) {
            for (int slot : new int[] { 10, 11, 14, 20, 22, 23 }) {
                long faddr = mem.getInt(toAddr(vt + slot * 4)) & 0xFFFFFFFFL;
                w.println("\n=== TCannonBullet::vt[" + slot + "] @ 0x" + Long.toHexString(faddr) + " ===");
                Function f = getFunctionAt(toAddr(faddr));
                if (f == null) {
                    try { f = createFunction(toAddr(faddr), "CannonVt" + slot); }
                    catch (Exception e) { w.println("  err: " + e.getMessage()); continue; }
                }
                if (f == null) continue;
                try {
                    DecompileResults dr = decomp.decompileFunction(f, 60, monitor);
                    if (dr != null && dr.getDecompiledFunction() != null) {
                        w.println(dr.getDecompiledFunction().getC());
                    }
                } catch (Exception e) { w.println("  err: " + e.getMessage()); }
            }
        }
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_cannon.txt");
    }
}

import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolIterator;
import java.io.FileWriter;
import java.io.PrintWriter;

/** Find TAdhesiveGrenade::vftable and decompile its per-tick / impact slots
 *  to locate the fuse timer field. We compare against TBullet & TLaser vt
 *  layouts (slot 10 = per-tick is the same across bullet subclasses). */
public class DecompAdhVt extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_adh_vt.txt"));
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        Memory mem = currentProgram.getMemory();

        long vt = 0;
        SymbolIterator it = currentProgram.getSymbolTable().getAllSymbols(true);
        while (it.hasNext()) {
            Symbol s = it.next();
            String n = s.getName(true);
            if (n != null && n.contains("TAdhesiveGrenade") && n.contains("vftable")) {
                vt = s.getAddress().getOffset();
                w.println("found " + n + " @ 0x" + Long.toHexString(vt));
                break;
            }
        }
        if (vt == 0) {
            // Fallback: scan known bullet-subclass vftable range
            for (long a = 0x00558000L; a < 0x00559000L; a += 4) {
                // Heuristic: skip — just give up; ctor decomp can be re-read.
            }
            w.println("vftable symbol NOT found");
            w.close();
            return;
        }

        // Decompile slots 9..30 — bullets typically have:
        //   slot 9 = "register with engine" / FUN_004b3a90 callee
        //   slot 10 = per-tick
        //   slot 11 = think variant
        //   slot 14 = OnDamage / OnImpact
        //   slot 20 = impact effect
        //   slot 22 = fire/extend (laser-specific)
        for (int slot = 9; slot <= 30; slot++) {
            long faddr = mem.getInt(toAddr(vt + slot * 4)) & 0xFFFFFFFFL;
            w.println("\n=== TAdhesiveGrenade::vt[" + slot + "] @ 0x" + Long.toHexString(faddr) + " ===");
            Function f = getFunctionAt(toAddr(faddr));
            if (f == null) {
                try { f = createFunction(toAddr(faddr), "AdhVt" + slot); }
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
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_adh_vt.txt");
    }
}

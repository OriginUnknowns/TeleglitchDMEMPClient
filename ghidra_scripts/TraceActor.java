import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolIterator;
import java.io.FileWriter;
import java.io.PrintWriter;

public class TraceActor extends GhidraScript {
    PrintWriter w;
    DecompInterface decomp;

    void d(long a, String tag) throws Exception {
        Function f = getFunctionAt(toAddr(a));
        if (f == null) f = createFunction(toAddr(a), null);
        if (f == null) { w.println("[no fn at 0x" + Long.toHexString(a) + "]"); return; }
        w.println("\n========== " + tag + " " + f.getName() + " @ 0x" + Long.toHexString(a) + " ==========");
        DecompileResults res = decomp.decompileFunction(f, 60, monitor);
        if (res.decompileCompleted() && res.getDecompiledFunction() != null) {
            w.println(res.getDecompiledFunction().getC());
        } else {
            w.println("[decomp failed]");
        }
    }

    @Override
    public void run() throws Exception {
        w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_actor.txt"));
        decomp = new DecompInterface();
        decomp.openProgram(currentProgram);

        // List all TActor / TMonster / Tzomb* / Tmob* etc class symbols
        w.println("=== Actor-ish class symbols ===");
        SymbolIterator it = currentProgram.getSymbolTable().getAllSymbols(true);
        int cnt = 0;
        while (it.hasNext()) {
            Symbol s = it.next();
            String pname = s.getParentNamespace() != null ? s.getParentNamespace().getName() : "";
            String low = pname.toLowerCase();
            if (low.equals("tactor") || low.startsWith("tmonster") || low.startsWith("tzomb")
                || low.startsWith("tenemy") || low.startsWith("tmob") || low.equals("tphysicalobject")
                || pname.equals("TProjectile")) {
                w.println(String.format("0x%08x  %s::%s", s.getAddress().getOffset(), pname, s.getName()));
                cnt++;
                if (cnt > 200) { w.println("... truncated"); break; }
            }
        }
        w.println("total: " + cnt);

        // Dump TActor + TPhysicalObject vtables (first 32 slots)
        w.println("\n=== TActor / TPhysicalObject vftables ===");
        SymbolIterator it2 = currentProgram.getSymbolTable().getAllSymbols(true);
        while (it2.hasNext()) {
            Symbol s = it2.next();
            String pname = s.getParentNamespace() != null ? s.getParentNamespace().getName() : "";
            if (!s.getName().equals("vftable")) continue;
            if (!(pname.equals("TActor") || pname.equals("TPhysicalObject") || pname.equals("TProjectile"))) continue;
            long base = s.getAddress().getOffset();
            w.println("\n--- " + pname + "::vftable @ 0x" + Long.toHexString(base) + " ---");
            for (int i = 0; i < 32; i++) {
                long slot = base + i * 4;
                long fa;
                try { fa = currentProgram.getMemory().getInt(toAddr(slot)) & 0xFFFFFFFFL; }
                catch (Exception e) { break; }
                if (fa < 0x400000 || fa > 0x600000) break;
                Function f = getFunctionAt(toAddr(fa));
                if (f == null) f = createFunction(toAddr(fa), null);
                String fname = (f != null) ? f.getName() : "<no-fn>";
                w.println(String.format("  [%2d] (+0x%02x) 0x%08x %s", i, i*4, fa, fname));
            }
        }

        // TPlayer's vtable[+0x70] = FUN_0044ee80 - the actual damage handler
        d(0x0044ee80L, "TPlayer::ApplyBulletDamage (own vftable[+0x70])");
        // And TPlayer's vtable[+0x68] for case 0x10 (wall?), vtable[+0x6c] for case 0x20, vtable[+0x74] for 0x100
        d(0x0044ef80L, "TPlayer vftable[+0x6c]");
        d(0x0044f130L, "TPlayer vftable[+0x74]");

        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_actor.txt");
    }
}

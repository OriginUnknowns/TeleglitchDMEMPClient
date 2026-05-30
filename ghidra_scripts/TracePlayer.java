import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolIterator;
import ghidra.program.model.symbol.Reference;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.HashSet;
import java.util.Set;

public class TracePlayer extends GhidraScript {
    PrintWriter w;
    DecompInterface decomp;
    Set<Long> seen = new HashSet<>();

    void d(long a, String tag) throws Exception {
        if (seen.contains(a)) { w.println("[seen " + tag + " 0x" + Long.toHexString(a) + "]"); return; }
        seen.add(a);
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
        w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_player.txt"));
        decomp = new DecompInterface();
        decomp.openProgram(currentProgram);

        // CreatePlayer Lua binding
        d(0x00425b20L, "CreatePlayer Lua binding");

        // All TPlayer-family vftables and ctors
        w.println("\n=== TPlayer-family symbols ===");
        SymbolIterator it = currentProgram.getSymbolTable().getAllSymbols(true);
        int cnt = 0;
        while (it.hasNext()) {
            Symbol s = it.next();
            String pname = s.getParentNamespace() != null ? s.getParentNamespace().getName() : "";
            if (pname.startsWith("TPlayer") || pname.equals("TPhysicalObject") || pname.equals("TMonster")
                || pname.equals("TProjectile") || pname.startsWith("TMonster") || pname.startsWith("TZombi")) {
                w.println(String.format("0x%08x  %s::%s", s.getAddress().getOffset(), pname, s.getName()));
                cnt++;
                if (cnt > 200) { w.println("... truncated"); break; }
            }
        }
        w.println("total: " + cnt);

        // For any "vftable" found with player-like parent, dump first 30 slots
        w.println("\n=== Player/Mob vftable dumps ===");
        SymbolIterator it2 = currentProgram.getSymbolTable().getAllSymbols(true);
        while (it2.hasNext()) {
            Symbol s = it2.next();
            String pname = s.getParentNamespace() != null ? s.getParentNamespace().getName() : "";
            if (!s.getName().equals("vftable")) continue;
            if (!(pname.startsWith("TPlayer") || pname.equals("TMonster") || pname.startsWith("TZombi"))) continue;
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

        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_player.txt");
    }
}

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

public class FindTBulletVtable extends GhidraScript {
    PrintWriter w;
    DecompInterface decomp;

    @Override
    public void run() throws Exception {
        w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_tbullet_vtable.txt"));
        decomp = new DecompInterface();
        decomp.openProgram(currentProgram);

        // Find any symbol whose parent namespace contains "Bullet" or just "TBullet"
        w.println("=== All TBullet* / TNail / vftable symbols (namespace-scoped) ===");
        SymbolIterator it = currentProgram.getSymbolTable().getAllSymbols(true);
        int cnt = 0;
        while (it.hasNext()) {
            Symbol s = it.next();
            String pname = s.getParentNamespace() != null ? s.getParentNamespace().getName() : "";
            String n = s.getName();
            if (pname.contains("Bullet") || pname.contains("Nail") || pname.equals("TBullet")) {
                w.println(String.format("0x%08x  %s::%s", s.getAddress().getOffset(), pname, n));
                cnt++;
            }
            if (cnt > 500) { w.println("... truncated"); break; }
        }
        w.println("\ntotal: " + cnt);

        // Print vtable contents at any "vftable" symbol found with parent TBullet (likely 0x556c00ish range)
        w.println("\n=== Vtable dumps for TBullet-family symbols ===");
        SymbolIterator it2 = currentProgram.getSymbolTable().getAllSymbols(true);
        while (it2.hasNext()) {
            Symbol s = it2.next();
            String pname = s.getParentNamespace() != null ? s.getParentNamespace().getName() : "";
            if (!s.getName().equals("vftable")) continue;
            if (!(pname.startsWith("TBullet") || pname.equals("TNail") || pname.equals("TCannonBullet")
                  || pname.equals("TExplodingBullet"))) continue;
            long base = s.getAddress().getOffset();
            w.println("\n--- " + pname + "::vftable @ 0x" + Long.toHexString(base) + " ---");
            for (int i = 0; i < 48; i++) {
                long slot = base + i * 4;
                long fa;
                try { fa = currentProgram.getMemory().getInt(toAddr(slot)) & 0xFFFFFFFFL; }
                catch (Exception e) { break; }
                if (fa < 0x400000 || fa > 0x600000) break;
                Function f = getFunctionAt(toAddr(fa));
                if (f == null) f = createFunction(toAddr(fa), null);
                String fname = (f != null) ? f.getName() : "<no-fn>";
                w.println(String.format("  [%2d] 0x%08x %s", i, fa, fname));
            }
        }

        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_tbullet_vtable.txt");
    }
}

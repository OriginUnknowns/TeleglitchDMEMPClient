import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolIterator;
import java.io.FileWriter;
import java.io.PrintWriter;

// Wider sweep for any bullet/projectile/laser/electro-themed class symbols.
// The hand-rolled FindTBulletVtable only matched namespaces containing
// "Bullet" / "Nail"; this catches Laser / Electro / Railgun / Rocket etc.
public class FindAllBulletSubclasses extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_all_bullet_subclasses.txt"));
        String[] needles = { "Bullet", "Nail", "Laser", "Electro", "Railgun", "Rocket",
                             "Projectile", "Tesla", "Beam", "Explod" };
        SymbolIterator it = currentProgram.getSymbolTable().getAllSymbols(true);
        w.println("=== Class namespaces matching projectile-ish keywords ===");
        java.util.Set<String> seen = new java.util.TreeSet<>();
        while (it.hasNext()) {
            Symbol s = it.next();
            String pname = s.getParentNamespace() != null ? s.getParentNamespace().getName() : "";
            if (pname.isEmpty()) continue;
            boolean hit = false;
            for (String n : needles) if (pname.contains(n)) { hit = true; break; }
            if (!hit) continue;
            if (!seen.add(pname)) continue;
            w.println("  " + pname);
        }
        w.println("\n=== vftable symbols for those classes ===");
        SymbolIterator it2 = currentProgram.getSymbolTable().getAllSymbols(true);
        while (it2.hasNext()) {
            Symbol s = it2.next();
            if (!s.getName().equals("vftable")) continue;
            String pname = s.getParentNamespace() != null ? s.getParentNamespace().getName() : "";
            if (pname.isEmpty()) continue;
            boolean hit = false;
            for (String n : needles) if (pname.contains(n)) { hit = true; break; }
            if (!hit) continue;
            w.println(String.format("  %s::vftable @ 0x%08x", pname, s.getAddress().getOffset()));
        }
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_all_bullet_subclasses.txt");
    }
}

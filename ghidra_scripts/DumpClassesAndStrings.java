// Dump RTTI class names, functions with TBullet/TPlayer/CreateBullet/Shoot, and weapon-related strings.
// Run with: analyzeHeadless ... -postScript DumpClassesAndStrings.java
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.listing.Data;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolIterator;
import ghidra.program.model.symbol.SymbolTable;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.data.StringDataInstance;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DumpClassesAndStrings extends GhidraScript {
    @Override
    public void run() throws Exception {
        String out = "E:\\projects\\TMEMultiplayerClient\\ghidra_dump.txt";
        PrintWriter w = new PrintWriter(new FileWriter(out));

        w.println("=== RTTI CLASSES (symbols containing 'class' or starting with .?AV) ===");
        SymbolTable st = currentProgram.getSymbolTable();
        SymbolIterator it = st.getAllSymbols(true);
        int classCount = 0;
        while (it.hasNext()) {
            Symbol s = it.next();
            String n = s.getName();
            if (n.contains("TypeDescriptor") || n.contains("RTTI") || n.startsWith(".?AV") || n.startsWith(".?AU")) {
                w.println(String.format("%s @ %s", n, s.getAddress()));
                classCount++;
                if (classCount > 500) { w.println("... (truncated at 500)"); break; }
            }
        }
        w.println("Total RTTI-ish symbols: " + classCount);

        w.println("\n=== FUNCTIONS (all, name + addr) ===");
        FunctionIterator fit = currentProgram.getFunctionManager().getFunctions(true);
        int fc = 0;
        while (fit.hasNext()) {
            Function f = fit.next();
            w.println(String.format("0x%08x %s", f.getEntryPoint().getOffset(), f.getName()));
            fc++;
        }
        w.println("Total functions: " + fc);

        w.println("\n=== STRINGS containing weapon/bullet/shoot/damage keywords ===");
        DataIterator dit = currentProgram.getListing().getDefinedData(true);
        while (dit.hasNext()) {
            Data d = dit.next();
            StringDataInstance sdi = StringDataInstance.getStringDataInstance(d);
            if (sdi == null || sdi == StringDataInstance.NULL_INSTANCE) continue;
            String s = sdi.getStringValue();
            if (s == null) continue;
            String low = s.toLowerCase();
            if (low.contains("bullet") || low.contains("shoot") || low.contains("damage")
                || low.contains("pystol") || low.contains("weapon") || low.contains("createbullet")
                || low.contains("sethealth") || low.contains("takedamage") || low.contains("playershoot")
                || low.contains("fire") || low.contains("attack") || low.contains("hit")) {
                w.println(String.format("0x%08x \"%s\"", d.getAddress().getOffset(), s.replace("\n","\\n").replace("\r","\\r")));
            }
        }

        w.close();
        println("WROTE: " + out);
    }
}

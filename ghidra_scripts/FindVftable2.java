import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSet;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Data;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolIterator;
import ghidra.program.model.symbol.Reference;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.HashSet;
import java.util.Set;

public class FindVftable2 extends GhidraScript {
    PrintWriter w;
    DecompInterface decomp;

    void dumpFn(long fa, String tag) throws Exception {
        Function f = getFunctionAt(toAddr(fa));
        if (f == null) f = createFunction(toAddr(fa), null);
        if (f == null) { w.println("[" + tag + " no fn at 0x" + Long.toHexString(fa) + "]"); return; }
        w.println("\n--- " + tag + " " + f.getName() + " @ 0x" + Long.toHexString(fa) + " ---");
        DecompileResults res = decomp.decompileFunction(f, 60, monitor);
        if (res.decompileCompleted() && res.getDecompiledFunction() != null) {
            w.println(res.getDecompiledFunction().getC());
        } else {
            w.println("[decomp failed]");
        }
    }

    @Override
    public void run() throws Exception {
        w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_vtable2.txt"));
        decomp = new DecompInterface();
        decomp.openProgram(currentProgram);

        // Find symbols containing "vftable" or "TBullet" via symbol table iteration
        w.println("=== SYMBOLS containing 'vftable' or 'TBullet' or 'vtbl' ===");
        SymbolIterator it = currentProgram.getSymbolTable().getAllSymbols(true);
        int cnt = 0;
        while (it.hasNext()) {
            Symbol s = it.next();
            String n = s.getName();
            if (n.contains("vftable") || n.contains("TBullet") || n.contains("vtbl") || n.contains("vtable")) {
                w.println(String.format("0x%08x %s (parent=%s)", s.getAddress().getOffset(), n,
                    s.getParentNamespace() != null ? s.getParentNamespace().getName() : "<no-ns>"));
                cnt++;
                if (cnt > 200) { w.println("... truncated"); break; }
            }
        }
        w.println("total: " + cnt);

        // Decompile all unique callers of TBullet ctor to find native shoot path
        long[] callers = {0x00454950L, 0x0045a1f0L, 0x00468b40L, 0x0046b7e0L,
                          0x0046ce70L, 0x00470c40L, 0x00497140L, 0x00497200L, 0x0046e330L};
        for (long c : callers) {
            dumpFn(c, "CTOR-CALLER");
        }

        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_vtable2.txt");
    }
}

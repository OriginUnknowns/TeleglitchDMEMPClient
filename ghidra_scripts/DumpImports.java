import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolIterator;
import ghidra.program.model.symbol.SymbolTable;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.mem.MemoryBlock;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DumpImports extends GhidraScript {
    PrintWriter w;
    SymbolTable st;

    void probe(long iat, String tag) throws Exception {
        Address a = toAddr(iat);
        w.println("\n-- IAT slot " + tag + " @ 0x" + Long.toHexString(iat) + " --");
        try {
            long ptr = getInt(a) & 0xffffffffL;
            w.println("   stored ptr = 0x" + Long.toHexString(ptr));
            Symbol sp = getSymbolAt(toAddr(ptr));
            if (sp != null) w.println("   target symbol = " + sp.getName() + "  (ns=" + sp.getParentNamespace().getName() + ")");
        } catch (Exception e) { w.println("   [read failed: " + e + "]"); }
        Symbol[] syms = st.getSymbols(a);
        for (Symbol s : syms) {
            w.println("   symbol@slot = " + s.getName() + "  source=" + s.getSource()
                + "  ns=" + s.getParentNamespace().getName());
        }
    }

    @Override
    public void run() throws Exception {
        w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_imports.txt"));
        st = currentProgram.getSymbolTable();

        w.println("===== MEMORY BLOCKS =====");
        for (MemoryBlock b : currentProgram.getMemory().getBlocks()) {
            w.println(String.format("  %-14s 0x%08x - 0x%08x  %s", b.getName(),
                b.getStart().getOffset(), b.getEnd().getOffset(),
                (b.isRead()?"r":"-")+(b.isWrite()?"w":"-")+(b.isExecute()?"x":"-")));
        }

        w.println("\n===== ALLOC IAT SLOTS =====");
        probe(0x00530398L, "operator_new");
        probe(0x0053039cL, "operator_delete");
        probe(0x00530320L, "malloc");
        probe(0x00530324L, "free");

        w.println("\n===== EXTERNAL (imported) SYMBOLS matching alloc/heap/new/delete =====");
        SymbolIterator it = st.getExternalSymbols();
        while (it.hasNext()) {
            Symbol s = it.next();
            String n = s.getName();
            String ln = n.toLowerCase();
            if (ln.contains("alloc") || ln.contains("free") || ln.contains("heap")
                || ln.contains("malloc") || ln.startsWith("operator") || ln.contains("new")
                || ln.contains("delete")) {
                w.println("  " + s.getParentNamespace().getName() + " :: " + n);
            }
        }

        w.println("\n===== ALL IMPORTED LIBRARIES (external namespaces) =====");
        java.util.Set<String> libs = new java.util.TreeSet<>();
        SymbolIterator it2 = st.getExternalSymbols();
        while (it2.hasNext()) {
            Symbol s = it2.next();
            libs.add(s.getParentNamespace().getName());
        }
        for (String l : libs) w.println("  " + l);

        w.println("\n===== HeapAlloc/HeapFree/etc references =====");
        SymbolIterator allIt = st.getAllSymbols(true);
        while (allIt.hasNext()) {
            Symbol s = allIt.next();
            String n = s.getName();
            if (n.equals("HeapAlloc") || n.equals("HeapFree") || n.equals("HeapCreate")
                || n.equals("VirtualAlloc") || n.equals("RtlAllocateHeap") || n.equals("GetProcessHeap")) {
                w.println("  " + n + " @ " + s.getAddress() + "  ns=" + s.getParentNamespace().getName());
                int cnt = 0;
                for (Reference r : getReferencesTo(s.getAddress())) {
                    w.println("       <- ref from 0x" + Long.toHexString(r.getFromAddress().getOffset())
                        + " (" + r.getReferenceType() + ")");
                    if (++cnt > 8) { w.println("       ..."); break; }
                }
            }
        }

        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_imports.txt");
    }
}

import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Data;
import ghidra.program.model.symbol.Reference;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompInputCam extends GhidraScript {
    PrintWriter w;
    DecompInterface decomp;

    void dumpFn(long fa, String label) throws Exception {
        Function f = getFunctionAt(toAddr(fa));
        w.println("\n========== " + label + " @ 0x" + Long.toHexString(fa) + " ==========");
        if (f == null) { w.println("[no fn]"); return; }
        DecompileResults res = decomp.decompileFunction(f, 60, monitor);
        if (res.decompileCompleted() && res.getDecompiledFunction() != null) {
            w.println(res.getDecompiledFunction().getC());
        } else {
            w.println("[decomp failed: " + res.getErrorMessage() + "]");
        }
    }

    void dumpXrefs(long ga, String label) throws Exception {
        Address a = toAddr(ga);
        w.println("\n=== XREFS to " + label + " @ 0x" + Long.toHexString(ga) + " ===");
        for (Reference r : getReferencesTo(a)) {
            Function f = getFunctionContaining(r.getFromAddress());
            w.println("  " + r.getReferenceType() + " from 0x" + r.getFromAddress() + (f != null ? (" in " + f.getName()) : ""));
        }
    }

    @Override
    public void run() throws Exception {
        w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_inputcam.txt"));
        decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        // Input/command device global writers + the raw key check + think2 camera helper
        dumpXrefs(0x00574798L, "DAT_00574798 (command/input device)");
        dumpFn(0x004b8780L, "FUN_004b8780 (raw key check, keycode arg)");
        dumpFn(0x0045b9d0L, "FUN_0045b9d0 (think2 helper - camera?)");
        dumpFn(0x0040e700L, "FUN_0040e700 (think2 helper)");
        dumpFn(0x004542f0L, "FUN_004542f0 (alive-think writes +0x1b8/1bc)");
        // who writes the input device global
        dumpXrefs(0x00574798L, "DAT_00574798 again");
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_inputcam.txt");
    }
}

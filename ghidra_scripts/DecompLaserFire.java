import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.mem.Memory;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompLaserFire extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_laser_fire.txt"));
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        // TLaser vt[22] (slot 22 = +0x58). Read it from the vtable.
        Memory mem = currentProgram.getMemory();
        long vt22Addr = mem.getInt(toAddr(0x005584bcL + 22L * 4)) & 0xFFFFFFFFL;
        w.println("=== TLaser vt[22] @ 0x" + Long.toHexString(vt22Addr) + " ===");
        Function f = getFunctionAt(toAddr(vt22Addr));
        if (f == null) f = createFunction(toAddr(vt22Addr), "TLaser_Fire");
        DecompileResults dr = decomp.decompileFunction(f, 60, monitor);
        if (dr != null && dr.getDecompiledFunction() != null) {
            w.println(dr.getDecompiledFunction().getC());
        }
        // Also vt[10] (slot 10 = +0x28) — typical per-tick update
        long vt10Addr = mem.getInt(toAddr(0x005584bcL + 10L * 4)) & 0xFFFFFFFFL;
        w.println("\n=== TLaser vt[10] @ 0x" + Long.toHexString(vt10Addr) + " ===");
        Function f10 = getFunctionAt(toAddr(vt10Addr));
        if (f10 == null) f10 = createFunction(toAddr(vt10Addr), "TLaser_Tick");
        DecompileResults dr10 = decomp.decompileFunction(f10, 60, monitor);
        if (dr10 != null && dr10.getDecompiledFunction() != null) {
            w.println(dr10.getDecompiledFunction().getC());
        }
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_laser_fire.txt");
    }
}

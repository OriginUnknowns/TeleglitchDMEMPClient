import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompTick extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_tick.txt"));
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        // TBullet/TLaser shared vt[10] (FUN_00498ad0) — probably where the
        // raycast-callback hit gets processed into damage.
        Address a = toAddr(0x00498ad0L);
        Function f = getFunctionAt(a);
        if (f == null) f = createFunction(a, "vt10_tick");
        w.println("=== vt[10] / FUN_00498ad0 ===");
        DecompileResults dr = decomp.decompileFunction(f, 120, monitor);
        if (dr != null && dr.getDecompiledFunction() != null) {
            w.println(dr.getDecompiledFunction().getC());
        }
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_tick.txt");
    }
}

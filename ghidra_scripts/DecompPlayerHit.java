import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.mem.Memory;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompPlayerHit extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_player_hit.txt"));
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        Memory mem = currentProgram.getMemory();

        // TPlayer::vftable @ 0x556b14 — slot 19 (+0x4c) is called by vt[10]
        // when bullet hits a type-2 entity. If TPlayer overrides it to
        // filter laser bullets, that's why players don't take laser damage.
        long playerVt = 0x00556b14L;
        // Also the TActor vt[19] for comparison
        long actorVt = 0x00556594L;

        for (int slot : new int[] { 19, 24, 28 }) {
            for (int j = 0; j < 2; j++) {
                long base = (j == 0) ? playerVt : actorVt;
                String cls = (j == 0) ? "TPlayer" : "TActor";
                long addr = mem.getInt(toAddr(base + slot * 4)) & 0xFFFFFFFFL;
                w.println("\n=== " + cls + "::vt[" + slot + "] @ 0x" + Long.toHexString(addr) + " ===");
                Function f = getFunctionAt(toAddr(addr));
                if (f == null) {
                    try { f = createFunction(toAddr(addr), cls + "_vt" + slot); }
                    catch (Exception e) { w.println("  (create fn err: " + e.getMessage() + ")"); continue; }
                }
                if (f == null) continue;
                try {
                    DecompileResults dr = decomp.decompileFunction(f, 60, monitor);
                    if (dr != null && dr.getDecompiledFunction() != null) {
                        w.println(dr.getDecompiledFunction().getC());
                    }
                } catch (Exception e) {
                    w.println("  (decomp err: " + e.getMessage() + ")");
                }
            }
        }
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_player_hit.txt");
    }
}

import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompDtors extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_dtors.txt"));
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        // Dump TBullet/TLaser vtable slots 0,1 + the TLaser-specific entries
        // we haven't seen. Slot 0 in MSVC is typically `scalar deleting destructor`
        // — takes a flag (1 = delete, 0 = no-delete). That's what we want to
        // call after vt[22] to clean the laser up.
        long[] addrs = {
            0x004959b0L,  // TBullet vt[0]
            0x00495880L,  // TBullet vt[1]
        };
        // Also: read TLaser vtable + its first few slots
        Address vtl = toAddr(0x005584bcL);
        w.println("=== TLaser::vftable @ 0x5584bc — first 8 slots ===");
        for (int i = 0; i < 8; i++) {
            long off = 0x5584bcL + i * 4;
            long fa = currentProgram.getMemory().getInt(toAddr(off)) & 0xFFFFFFFFL;
            w.println(String.format("  [%d] 0x%08x", i, fa));
        }
        for (long a : addrs) {
            Address addr = toAddr(a);
            Function f = getFunctionAt(addr);
            if (f == null) f = createFunction(addr, "vt_slot");
            w.println("\n=== 0x" + Long.toHexString(a) + " ===");
            DecompileResults dr = decomp.decompileFunction(f, 30, monitor);
            if (dr != null && dr.getDecompiledFunction() != null) {
                w.println(dr.getDecompiledFunction().getC());
            }
        }
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_dtors.txt");
    }
}

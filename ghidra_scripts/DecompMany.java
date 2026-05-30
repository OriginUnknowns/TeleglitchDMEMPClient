import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompMany extends GhidraScript {
    PrintWriter w;
    DecompInterface decomp;

    void d(long a) throws Exception {
        Function f = getFunctionAt(toAddr(a));
        if (f == null) f = createFunction(toAddr(a), null);
        if (f == null) { w.println("[no fn at 0x" + Long.toHexString(a) + "]"); return; }
        w.println("\n========== " + f.getName() + " @ 0x" + Long.toHexString(a) + " ==========");
        DecompileResults res = decomp.decompileFunction(f, 60, monitor);
        if (res.decompileCompleted() && res.getDecompiledFunction() != null) {
            w.println(res.getDecompiledFunction().getC());
        } else {
            w.println("[decomp failed]");
        }
    }

    @Override
    public void run() throws Exception {
        w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_bullet_methods.txt"));
        decomp = new DecompInterface();
        decomp.openProgram(currentProgram);

        // TBullet vtable methods (focus on bullet-specific slots)
        d(0x004959b0L);  // [0] - likely Update/Move (TBullet, TCannonBullet share; TNail/TExp differ)
        d(0x00495880L);  // [1]
        d(0x00495850L);  // [2]
        d(0x00498ad0L);  // [10] - same across all 4 bullet types
        d(0x00496c50L);  // [12]
        d(0x00497510L);  // [14] - TCannonBullet overrides
        d(0x00496920L);  // [20] - TCannonBullet overrides
        d(0x00496a10L);  // [21]
        d(0x00498f50L);  // [22] - TNail overrides

        // TBullet ctor base call
        d(0x00498920L);  // base class ctor (called by 0x497040)

        // TRayCastBulletCallback first few vtable slots
        // Read the vtable from 0x5587f4
        long rcvt = 0x005587f4L;
        for (int i = 0; i < 6; i++) {
            long fa = currentProgram.getMemory().getInt(toAddr(rcvt + i*4)) & 0xFFFFFFFFL;
            if (fa < 0x400000 || fa > 0x600000) break;
            w.println("\n>>> TRayCastBulletCallback::vftable[" + i + "] = 0x" + Long.toHexString(fa));
            d(fa);
        }

        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_bullet_methods.txt");
    }
}

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.scalar.Scalar;
import java.io.FileWriter;
import java.io.PrintWriter;

// Find the RET instruction at the tail of each subclass ctor and dump its
// purge amount. RET N / 4 = number of 4-byte stack args the callee cleans.
// Mismatched purge between our hook signature and the real ctor = silent
// stack corruption every call → eventually DEP at a stack address.
public class GetCtorRetPurge extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_ctor_ret_purges.txt"));
        long[] ctors = { 0x00497040L, 0x00497660L, 0x00497140L, 0x00497200L,
                         0x00497cd0L, 0x00499d70L, 0x0049a5c0L, 0x0049aa10L };
        String[] names = { "TBullet", "TCannonBullet", "TExplodingBullet", "TNail",
                           "TLaser", "TRailgunRay", "TRocket", "TBlueRocket" };
        for (int i = 0; i < ctors.length; i++) {
            Address a = toAddr(ctors[i]);
            Function f = getFunctionAt(a);
            if (f == null) f = createFunction(a, names[i] + "_ctor");
            w.println("== " + names[i] + " ctor @ 0x" + Long.toHexString(ctors[i]) + " ==");
            // Walk instructions in body, find every RET / RETN with imm.
            Instruction ins = getInstructionAt(a);
            int seen = 0;
            while (ins != null && f.getBody().contains(ins.getAddress())) {
                String mn = ins.getMnemonicString();
                if (mn.equals("RET") || mn.equals("RETN") || mn.equals("RETF")) {
                    seen++;
                    int purge = 0;
                    if (ins.getNumOperands() >= 1 && ins.getOpObjects(0).length > 0
                        && ins.getOpObjects(0)[0] instanceof Scalar) {
                        purge = (int)((Scalar)ins.getOpObjects(0)[0]).getUnsignedValue();
                    }
                    w.println(String.format("  0x%08x  %s 0x%x   (cleans %d stack arg slot(s))",
                        ins.getAddress().getOffset(), mn, purge, purge / 4));
                }
                ins = ins.getNext();
            }
            if (seen == 0) w.println("  (no RET found in body)");
            w.println();
        }
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_ctor_ret_purges.txt");
    }
}

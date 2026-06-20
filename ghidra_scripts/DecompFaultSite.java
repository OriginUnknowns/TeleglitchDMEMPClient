import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.address.Address;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompFaultSite extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_fault.txt"));
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        // Crash EIP = engine+0x17894. Default preferred PE base is 0x400000;
        // file address = 0x400000 + 0x17894 = 0x417894.
        // Also dump nearby fns from stack walk: +0x372FC, +0x32BE8, +0x3288C.
        long[] addrs = {
            0x00417894L,
            0x004372fcL,
            0x00432be8L,
            0x0043288cL
        };
        String[] names = { "fault_417894", "stack0_4372fc", "stack1_432be8", "stack2_43288c" };
        for (int i = 0; i < addrs.length; i++) {
            w.println("\n=== " + names[i] + " @ 0x" + Long.toHexString(addrs[i]) + " ===");
            Address a = toAddr(addrs[i]);
            Function f = getFunctionContaining(a);
            if (f == null) {
                try { f = createFunction(a, names[i]); } catch (Exception e) {}
            }
            if (f == null) {
                // Just dump a few instructions
                Instruction ins = getInstructionAt(a);
                for (int k = 0; k < 6 && ins != null; k++) {
                    w.println("  " + ins.getAddress() + ": " + ins);
                    ins = ins.getNext();
                }
                continue;
            }
            w.println("  containing fn = " + f.getName() + " @ " + f.getEntryPoint());
            try {
                DecompileResults dr = decomp.decompileFunction(f, 60, monitor);
                if (dr != null && dr.getDecompiledFunction() != null) {
                    w.println(dr.getDecompiledFunction().getC());
                }
            } catch (Exception e) { w.println("  err: " + e.getMessage()); }
        }
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_fault.txt");
    }
}

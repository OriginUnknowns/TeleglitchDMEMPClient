import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import java.io.FileWriter;
import java.io.PrintWriter;

/** Two crash sites in the engine's damage-tally iteration. Both AV on
 *  a corrupted "attacker" list element (engine's list memory was freed,
 *  Lua then reused it for 16 tables with "entity" key). Decompiling the
 *  containing functions lets us find the list shape + allocator. */
public class DecompCrashSites extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_crash_sites.txt"));
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        long[] addrs = {
            0x00417894L,   // crash #1 — mov eax,[edx+28] inside FUN_00417720
            0x00419757L,   // crash #2 — different EIP, same corrupted ecx
            0x00437222L,   // stack[0] for crash #2 — caller
            0x004c05edL,   // stack[1]
            0x00432cc9L,   // stack[2]
            0x00432891L,   // stack[3] (likely PThink / per-tick driver)
            0x00404819L    // joiner-side crash EIP (DEP fault)
        };
        String[] names = { "tally_call_vt10",
                           "tally_call_vt13_419757",
                           "stack0_437222",
                           "stack1_4c05ed",
                           "stack2_432cc9",
                           "stack3_432891",
                           "joiner_4819" };
        for (int i = 0; i < addrs.length; i++) {
            Address a = toAddr(addrs[i]);
            w.println("\n=== " + names[i] + " @ 0x" + Long.toHexString(addrs[i]) + " ===");
            Function f = getFunctionContaining(a);
            if (f == null) {
                try { f = createFunction(a, names[i]); } catch (Exception e) {}
            }
            if (f == null) {
                Instruction ins = getInstructionAt(a);
                for (int k = 0; k < 8 && ins != null; k++) {
                    w.println("  " + ins.getAddress() + ": " + ins);
                    ins = ins.getNext();
                }
                continue;
            }
            w.println("  containing fn: " + f.getName() + " @ " + f.getEntryPoint());
            try {
                DecompileResults dr = decomp.decompileFunction(f, 60, monitor);
                if (dr != null && dr.getDecompiledFunction() != null) {
                    w.println(dr.getDecompiledFunction().getC());
                }
            } catch (Exception e) { w.println("  err: " + e.getMessage()); }
        }
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_crash_sites.txt");
    }
}

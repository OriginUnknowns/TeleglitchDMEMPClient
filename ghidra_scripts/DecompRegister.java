import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import java.io.FileWriter;
import java.io.PrintWriter;

// 1) Decompile FUN_004b3a90 (the entity-register-with-world call invoked
//    after Lua CreateBullet's ctor) to confirm it works for any entity, not
//    just TBullet.
// 2) Dump the ~25 insns AFTER the engine's lasgun-fire ctor call
//    (0x46905f) so we know what registration it does itself (engine path
//    may use a different register call than the Lua binding).
public class DecompRegister extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_register.txt"));
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);

        // 1) FUN_004b3a90 — Lua binding's post-ctor register call
        Address regA = toAddr(0x004b3a90L);
        Function regF = getFunctionAt(regA);
        if (regF == null) regF = createFunction(regA, "RegisterFromLua");
        w.println("=== FUN_004b3a90 (post-Lua-ctor register) ===");
        DecompileResults dr = decomp.decompileFunction(regF, 60, monitor);
        if (dr != null && dr.getDecompiledFunction() != null) {
            w.println(dr.getDecompiledFunction().getC());
        }

        // 2) Disasm right AFTER engine's lasgun-fire ctor (0x46905f)
        w.println("\n=== Disasm after TLaser ctor at 0x46905f ===");
        Instruction ins = getInstructionAt(toAddr(0x0046905fL));
        if (ins != null) ins = ins.getNext();
        int i = 0;
        while (ins != null && i < 30) {
            w.println(String.format("  0x%08x  %s", ins.getAddress().getOffset(), ins.toString()));
            ins = ins.getNext();
            i++;
        }

        // 3) Disasm right AFTER engine's cannon-fire ctor (0x46e8a6)
        w.println("\n=== Disasm after TCannon ctor at 0x46e8a6 ===");
        ins = getInstructionAt(toAddr(0x0046e8a6L));
        if (ins != null) ins = ins.getNext();
        i = 0;
        while (ins != null && i < 30) {
            w.println(String.format("  0x%08x  %s", ins.getAddress().getOffset(), ins.toString()));
            ins = ins.getNext();
            i++;
        }

        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_register.txt");
    }
}

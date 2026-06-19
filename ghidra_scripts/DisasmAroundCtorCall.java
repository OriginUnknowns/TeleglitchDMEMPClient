import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Instruction;
import java.io.FileWriter;
import java.io.PrintWriter;

// Dump ~25 instructions BEFORE each subclass-ctor call site. The PUSH /
// MOV / lea sequence right before the CALL is the arg-prep code — that
// tells us exactly which Lua-side numbers (x, y, vx, vy, dmg, owner,
// force, ...) map to which ctor stack slot, and what the engine constants
// are. Without this we'd be guessing at ABI.
public class DisasmAroundCtorCall extends GhidraScript {
    long[] sites = {
        0x0046e8a6L,  // TCannon
        0x0046905fL,  // TLaser (lasgun shoot path)
        0x0046ebd3L,  // TLaser (second site — probably aim ray or beam)
        0x0046eef5L,  // TRailgunRay
        0x00422935L,  // TRocket
        0x00422ac5L,  // TRocket
        0x00046a59eL  // TBlueRocket — typo guard
    };
    String[] names = { "TCannon@46e8a6", "TLaser@46905f", "TLaser@46ebd3",
                       "TRailgun@46eef5", "TRocket@422935", "TRocket@422ac5", "TBlueRocket@46a59e" };

    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_ctor_arg_disasm.txt"));
        for (int i = 0; i < sites.length; i++) {
            Address ca = toAddr(sites[i]);
            Instruction ci = getInstructionAt(ca);
            if (ci == null) { w.println("== " + names[i] + " — no insn at addr"); continue; }
            w.println("\n=== " + names[i] + " ===");
            // Collect last ~35 instructions before the call.
            java.util.ArrayDeque<Instruction> buf = new java.util.ArrayDeque<>();
            Instruction p = ci.getPrevious();
            int n = 0;
            while (p != null && n < 35) {
                buf.push(p);
                p = p.getPrevious();
                n++;
            }
            for (Instruction x : buf) {
                w.println(String.format("  0x%08x  %s", x.getAddress().getOffset(), x.toString()));
            }
            w.println(String.format("  0x%08x  %s   <-- CTOR CALL", ci.getAddress().getOffset(), ci.toString()));
        }
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_ctor_arg_disasm.txt");
    }
}

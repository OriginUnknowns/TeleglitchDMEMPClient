import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.*;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;

public class LookupCaller extends GhidraScript {
    @Override
    public void run() throws Exception {
        // The instr that called purecall. Stack ret value is the addr AFTER the call.
        // So the call instr ends 5 bytes before (E8 + 4-byte rel32). Check 0x4028f4-5 = 0x4028ef.
        long[] retAddrs = { 0x004028f4L, 0x0041975cL };
        for (long ret : retAddrs) {
            println("==== caller of return-addr 0x" + Long.toHexString(ret) + " ====");
            // Look at 5 bytes before for E8 rel32 call
            for (int d = 3; d <= 7; d++) {
                Address probe = toAddr(ret - d);
                Instruction ins = getInstructionAt(probe);
                if (ins != null) {
                    println("  instr at -" + d + " bytes: " + probe + ": " + ins.toString());
                    if (ins.getMnemonicString().startsWith("CALL")) {
                        println("    ^^^^ CALL — caller fn:");
                        Function caller = getFunctionContaining(probe);
                        if (caller != null) {
                            println("    " + caller.getName() + " @ " + caller.getEntryPoint() +
                                    " (call at offset +0x" + Long.toHexString(probe.subtract(caller.getEntryPoint())) + ")");
                            DecompInterface d2 = new DecompInterface();
                            d2.openProgram(currentProgram);
                            DecompileResults r = d2.decompileFunction(caller, 30, monitor);
                            println(r.getDecompiledFunction().getC());
                        }
                    }
                }
            }
        }
    }
}

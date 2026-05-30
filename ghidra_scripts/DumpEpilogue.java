import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DumpEpilogue extends GhidraScript {
    PrintWriter w;

    void dump(long fa, String tag) throws Exception {
        Function f = getFunctionAt(toAddr(fa));
        w.println("\n==== " + tag + " @ 0x" + Long.toHexString(fa) + " ====");
        if (f != null) {
            w.println("name=" + f.getName() + " callconv=" + f.getCallingConventionName()
                + " params=" + f.getParameterCount() + " stackPurge=" + f.getStackPurgeSize()
                + " sig=" + f.getSignature());
        } else {
            w.println("(no function object)");
        }
        // Walk instructions, print all RET and the first ~6 + last ~10
        InstructionIterator it = currentProgram.getListing().getInstructions(toAddr(fa), true);
        int n = 0;
        Function fn = getFunctionAt(toAddr(fa));
        Address end = (fn != null) ? fn.getBody().getMaxAddress() : toAddr(fa + 0x400);
        while (it.hasNext()) {
            Instruction ins = it.next();
            if (ins.getAddress().getOffset() > end.getOffset()) break;
            String m = ins.getMnemonicString();
            boolean isRet = m.toLowerCase().startsWith("ret");
            if (n < 6 || isRet) {
                w.println(String.format("  0x%08x %s", ins.getAddress().getOffset(), ins.toString()));
            }
            n++;
        }
    }

    @Override
    public void run() throws Exception {
        w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_epilogue.txt"));
        dump(0x00497040L, "BulletCtor (hooked)");
        dump(0x0044ee80L, "CentralHit (hooked)");
        // Also the base ctor and the real call site for context
        dump(0x00425ca0L, "CreateBullet binding (caller)");
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_epilogue.txt");
    }
}

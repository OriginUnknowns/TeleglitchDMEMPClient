import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.mem.Memory;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DisasmSites extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_disasm_sites.txt"));
        Memory mem = currentProgram.getMemory();
        long[] addrs = { 0x00417890L, 0x00419750L, 0x00419755L, 0x00419757L };
        for (long base : addrs) {
            w.println("\n=== bytes at 0x" + Long.toHexString(base) + " ===");
            StringBuilder s = new StringBuilder();
            for (int i = 0; i < 32; i++) {
                Address a = toAddr(base + i);
                if (i % 16 == 0) s.append(String.format("\n  %08x: ", base + i));
                try {
                    s.append(String.format("%02X ", mem.getByte(a) & 0xFF));
                } catch (Exception e) {
                    s.append("?? ");
                }
            }
            w.println(s.toString());
        }
        w.close();
        println("WROTE");
    }
}

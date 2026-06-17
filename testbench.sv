`timescale 1ns/1ps

//====================================================
// INTERFACE
//====================================================
interface sram_if(input logic clk);
    logic        cs;
    logic        we;
    logic        oe;
    logic [10:0] addr;
    logic [15:0] wdata;
    logic [15:0] rdata;
    logic        sec_err;
    logic        ded_err;
endinterface

//====================================================
// TRANSACTION
//====================================================
class sram_transaction;
    rand bit [10:0] addr;
    rand bit [15:0] wdata;
    rand bit cs;
    rand bit we;
    rand bit oe;
    
    logic [15:0] rdata;
    logic        sec_err;
    logic        ded_err;

    constraint ctrl_pins {
        cs == 1; 
        (we == 1) -> (oe == 0); 
        (we == 0) -> (oe == 1);
    }
endclass

//====================================================
// GENERATOR
//====================================================
class generator;
    mailbox #(sram_transaction) mbx;
    event ended;
    int repeat_count;
    bit [10:0] written_addrs[$]; 

    function new(mailbox #(sram_transaction) mbx, event ended);
        this.mbx   = mbx;
        this.ended = ended;
    endfunction

    task run();
        sram_transaction trans;

        // Phase 1: WRITE
        for(int i = 0; i < (repeat_count / 2); i++) begin
            trans = new();
            
            if (written_addrs.size() > 0) begin
                // Force randomizer to pick a brand NEW address not in the queue
                if(!trans.randomize() with {
                    we == 1; 
                    oe == 0; 
                    !(addr inside {written_addrs}); 
                }) $fatal(1, "Gen: Write fail");
            end else begin
                if(!trans.randomize() with {we == 1; oe == 0;}) $fatal(1, "Gen: Write fail");
            end
            
            written_addrs.push_back(trans.addr); 
            mbx.put(trans);
        end

        // Phase 2: READ (Sequential to match backdoor logic)
        for(int i = 0; i < (repeat_count / 2); i++) begin
            trans = new();
            if(!trans.randomize() with {we == 0; oe == 1;}) $fatal(1, "Gen: Read fail");
            trans.addr = written_addrs[i]; 
            mbx.put(trans);
        end

        -> ended;
    endtask
endclass

//====================================================
// DRIVER
//====================================================
class driver;
    mailbox #(sram_transaction) mbx;
    virtual sram_if vif;
    int no_transactions = 0;

    function new(mailbox #(sram_transaction) mbx, virtual sram_if vif);
        this.mbx = mbx;
        this.vif = vif;
    endfunction

    task run();
        sram_transaction trans;
        forever begin
            mbx.get(trans);
            @(posedge vif.clk);
            vif.cs    <= trans.cs;
            vif.we    <= trans.we;
            vif.oe    <= trans.oe;
            vif.addr  <= trans.addr;
            vif.wdata <= trans.wdata;
            no_transactions++;
        end
    endtask
endclass

//====================================================
// MONITOR
//====================================================
class monitor;
    virtual sram_if vif;
    mailbox #(sram_transaction) mbx;

    function new(virtual sram_if vif, mailbox #(sram_transaction) mbx);
        this.vif = vif;
        this.mbx = mbx;
    endfunction

    task run();
        sram_transaction trans;
        forever begin
            @(posedge vif.clk);
            #1; // Wait for NBA region to settle
            
            if(vif.cs) begin
                trans = new();
                trans.cs    = vif.cs;
                trans.we    = vif.we;
                trans.oe    = vif.oe;
                trans.addr  = vif.addr;
                trans.wdata = vif.wdata;

                if(trans.we) begin
                    mbx.put(trans);
                end 
                else if(!trans.we && trans.oe) begin
                    fork
                        begin
                            sram_transaction local_trans = trans; 
                            @(posedge vif.clk); 
                            #1; 
                            local_trans.rdata   = vif.rdata;
                            local_trans.sec_err = vif.sec_err;
                            local_trans.ded_err = vif.ded_err;
                            mbx.put(local_trans);
                        end
                    join_none
                end
            end
        end
    endtask
endclass

//====================================================
// SCOREBOARD
//====================================================
class scoreboard;
    mailbox #(sram_transaction) mbx;
    logic [15:0] golden_mem [0:2047];

    function new(mailbox #(sram_transaction) mbx);
        this.mbx = mbx;
        foreach(golden_mem[i]) golden_mem[i] = 16'h0000;
    endfunction

    task run();
        sram_transaction trans;
        forever begin
            mbx.get(trans);
            if(trans.cs) begin
                if(trans.we) begin
                    golden_mem[trans.addr] = trans.wdata;
                end
                else if(!trans.we && trans.oe) begin
                    
                    if(trans.sec_err) $display("   -> [WARNING] Single Error Corrected by Hardware!");
                    if(trans.ded_err) $display("   -> [FATAL] Double Error Flagged by Hardware!");

                    if(trans.rdata === golden_mem[trans.addr]) begin
                        $display("[SCOREBOARD] PASS addr=0x%03h | Expected=0x%04h | Got=0x%04h", trans.addr, golden_mem[trans.addr], trans.rdata);
                    end else begin
                        if (trans.ded_err) begin
                            $display("[SCOREBOARD] EXPECTED FAIL (DED) addr=0x%03h | Expected=0x%04h | Got=0x%04h", trans.addr, golden_mem[trans.addr], trans.rdata);
                        end else begin
                            $error("[SCOREBOARD] CRITICAL FAIL addr=0x%03h | Expected=0x%04h | Got=0x%04h", trans.addr, golden_mem[trans.addr], trans.rdata);
                        end
                    end
                    $display("---------------------------------------------------------");
                end
            end
        end
    endtask
endclass

//====================================================
// ENVIRONMENT
//====================================================
class environment;
    generator  gen;
    driver     driv;
    monitor    mon;
    scoreboard scb;
    mailbox #(sram_transaction) gen2driv;
    mailbox #(sram_transaction) mon2scb;
    event gen_ended;
    virtual sram_if vif;

    function new(virtual sram_if vif);
        this.vif = vif;
        gen2driv = new();
        mon2scb  = new();
        gen  = new(gen2driv, gen_ended);
        driv = new(gen2driv, vif);
        mon  = new(vif, mon2scb);
        scb  = new(mon2scb);
    endfunction

    task test();
        fork
            gen.run();
            driv.run();
            mon.run();
            scb.run();
        join_none
    endtask

    task run();
        test();
        wait(driv.no_transactions == gen.repeat_count);
        #50;
        $display("=================================");
        $display("TEST COMPLETED");
        $display("=================================");
        $finish;
    endtask
endclass

//====================================================
// TOP TESTBENCH
//====================================================
module tb;
    logic clk;
    always #5 clk = ~clk;

    sram_if intf(clk);

    sram_2kx16_secded dut(
        .clk     (intf.clk),
        .cs      (intf.cs),
        .we      (intf.we),
        .oe      (intf.oe),
        .addr    (intf.addr),
        .wdata   (intf.wdata),
        .rdata   (intf.rdata),
        .sec_err (intf.sec_err),
        .ded_err (intf.ded_err)
    );

    environment env;

    initial begin
        int target_addr; // Fixed static declaration

        clk = 0;
        env = new(intf);
        env.gen.repeat_count = 200; // 100 Writes, 100 Reads
        
        env.test();

        wait(env.driv.no_transactions == 100);
        $display("\n=========================================================");
        $display("BACKDOOR ERROR INJECTION PROTOCOL INITIATED...");
        $display("=========================================================");

        // Inject SINGLE errors into the first 50 written addresses
        for(int i = 0; i < 50; i++) begin
            target_addr = env.gen.written_addrs[i];
            dut.mem[target_addr][4] ^= 1'b1; 
        end
        $display("--> Injected Single Errors into 50 addresses.");

        // Inject DOUBLE errors into the next 50 written addresses
        for(int i = 50; i < 100; i++) begin
            target_addr = env.gen.written_addrs[i];
            dut.mem[target_addr][7]  ^= 1'b1; 
            dut.mem[target_addr][12] ^= 1'b1; 
        end
        $display("--> Injected Double Errors into 50 addresses.\n");

        wait(env.driv.no_transactions == env.gen.repeat_count);
        #50;
        $display("=================================");
        $display("TEST COMPLETED");
        $display("=================================");
        $finish;
    end
endmodule

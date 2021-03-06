`include "./cpu/cpu.v"
`include "./ram/ram1k_wb8.v"
`include "./leds/leds_wb8.v"
`include "./uart/uart_wb8.v"
`include "./spi/spi_wb8.v"
`include "./timer/timer_wb8.v"


module top(
        input clk_100mhz,
        // LED outputs on pmod header 1
        output pmod1_1, pmod1_2, pmod1_3, pmod1_4, pmod1_7, pmod1_8, pmod1_9, pmod1_10,
        // UART pins on pmod header 2
        input uart_rx,
        output uart_tx,
        // board LEDs
        output led1, led2,
        // SPI port 0
        input spi0_miso,
        output spi0_clk, spi0_mosi, spi0_cs,
        // push buttons
        input button0, button1, button2, button3
    );

    wire clk_pll, pll_locked;

    // generate 25 MHz clock
    SB_PLL40_PAD #(
		.FEEDBACK_PATH("SIMPLE"),
		.DELAY_ADJUSTMENT_MODE_FEEDBACK("FIXED"),
		.DELAY_ADJUSTMENT_MODE_RELATIVE("FIXED"),
		.PLLOUT_SELECT("GENCLK"),
		.FDA_FEEDBACK(4'b1111),
		.FDA_RELATIVE(4'b1111),
		.DIVR(4'b0000),
		.DIVF(7'b0000111),
		.DIVQ(3'b101),
		.FILTER_RANGE(3'b101)
	) pll (
		.PACKAGEPIN   (clk_100mhz),
		.PLLOUTGLOBAL (clk_pll),
		.LOCK         (pll_locked),
		.BYPASS       (1'b0      ),
		.RESETB       (1'b1      )
	);

    reg clk;
    assign clk = clk_pll;


    reg reset = 1;
    reg[7:0] resetcnt = 1;
    reg interrupt = button0;

    wire cpu_cyc, cpu_stb, cpu_we;
    wire[7:0] cpu_dat;
    wire[31:0] cpu_adr;

    reg[7:0] arbiter_dat_o;
    reg arbiter_ack_o;

    cpu cpu_inst(
        .CLK_I(clk),
	    .ACK_I(arbiter_ack_o),
	    .DAT_I(arbiter_dat_o),
	    .RST_I(reset),
        .INTERRUPT_I(interrupt),
	    .ADR_O(cpu_adr),
	    .DAT_O(cpu_dat),
	    .CYC_O(cpu_cyc),
	    .STB_O(cpu_stb),
	    .WE_O(cpu_we)
    );

    wire ram_ack;
    reg ram_stb;
    wire[7:0] ram_dat;

    ram1k_wb8 #(
        .RAMINITFILE("./boards/icoboard/asm/spi-test.dat")
    ) ram_inst (
	    .CLK_I(clk),
	    .STB_I(ram_stb),
	    .WE_I(cpu_we),
	    .ADR_I(cpu_adr[9:0]),
	    .DAT_I(cpu_dat),
	    .DAT_O(ram_dat),
	    .ACK_O(ram_ack)
    );

    reg leds_stb;
    wire[7:0] leds_value, leds_dat;
    wire leds_ack;

    leds_wb8 leds_inst(
        .CLK_I(clk),
        .DAT_I(cpu_dat),
        .STB_I(leds_stb),
        .WE_I(cpu_we),
        .DAT_O(leds_dat),
        .ACK_O(leds_ack),
        .O_leds(leds_value)
    );
    assign {pmod1_1, pmod1_2, pmod1_3, pmod1_4, pmod1_7, pmod1_8, pmod1_9, pmod1_10} = leds_value;

    reg uart_rx, uart_stb = 0;
    wire uart_tx, uart_ack;
    wire[7:0] uart_dat;

    uart_wb8 uart_inst(
        .CLK_I(clk),
        .ADR_I(cpu_adr[1:0]),
        .DAT_I(cpu_dat),
        .STB_I(uart_stb),
        .WE_I(cpu_we),
        .DAT_O(uart_dat),
        .ACK_O(uart_ack),
        .O_tx(uart_tx),
        .I_rx(uart_rx)
    );


    assign led1 = !uart_rx;
    assign led2 = !uart_tx;
    assign led3 = cpu_we;

    reg spi0_stb = 0;
    wire[7:0] spi0_dat;
    wire spi0_ack;

    spi_wb8 spi0_inst(
        .CLK_I(clk),
        .ADR_I(cpu_adr[1:0]),
        .DAT_I(cpu_dat),
        .STB_I(spi0_stb),
        .WE_I(cpu_we),
        .DAT_O(spi0_dat),
        .ACK_O(spi0_ack),
        .I_spi_miso(spi0_miso),
        .O_spi_mosi(spi0_mosi),
        .O_spi_clk(spi0_clk),
        .O_spi_cs(spi0_cs)
    );

    reg timer_stb = 0;
    wire[7:0] timer_dat;
    wire timer_ack;

    timer_wb8 timer_inst(
        .CLK_I(clk),
        .ADR_I(cpu_adr[1:0]),
        .DAT_I(cpu_dat),
        .STB_I(timer_stb),
        .WE_I(cpu_we),
        .DAT_O(timer_dat),
        .ACK_O(timer_ack)
    );

    // The iCE40 BRAMs always return zero for a while after device program and reset:
    // https://github.com/cliffordwolf/icestorm/issues/76
    // Assert reset for while until things should have settled.
    always @(posedge clk) begin
      if(resetcnt != 0) begin
        reset <= 1;
        resetcnt <= resetcnt + 1;
      end else reset <= 0;
    end


    // bus arbiter
    always @(*) begin
        ram_stb = 0;
        leds_stb = 0;
        uart_stb = 0;
        spi0_stb = 0;
        timer_stb = 0;

        case(cpu_adr[31:11])
            21'hFFFFFF: begin // 0xFFFFF8xxx - 0xFFFFFFFF: I/O devices
                case(cpu_adr[10:8])
                    0: begin // 0xFFFFF8xx: UART
                        arbiter_dat_o = uart_dat;
                        arbiter_ack_o = uart_ack;
                        uart_stb = cpu_stb;
                    end

                    1: begin // 0xFFFFF9xx: SPI port 0
                        arbiter_dat_o = spi0_dat;
                        arbiter_ack_o = spi0_ack;
                        spi0_stb = cpu_stb;
                    end

                    // 2: 0xFFFFFAxx
                    // 3: 0xFFFFFBxx
                    // 4: 0xFFFFFCxx 

                    5: begin // 0xFFFFFDxx: Timer
                        arbiter_dat_o = timer_dat;
                        arbiter_ack_o = timer_ack;
                        timer_stb = cpu_stb;
                    end

                    // 6: 0xFFFFFExx

                    default: begin // default I/O device: LEDs
                        arbiter_dat_o = leds_dat;
                        arbiter_ack_o = leds_ack;
                        leds_stb = cpu_stb;                      
                    end
                endcase
            end

            default: begin
                arbiter_dat_o = ram_dat;
                arbiter_ack_o = ram_ack;
                ram_stb = cpu_stb;
            end
        endcase

    end


endmodule
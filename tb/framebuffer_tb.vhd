library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity framebuffer_tb is
end entity;

architecture sim of framebuffer_tb is
  constant T       : time := 10 ns;
  constant LAST    : natural := 76799;          -- (239 * 320) + 319

  signal clk   : std_logic := '0';
  signal we    : std_logic := '0';
  signal waddr : unsigned(16 downto 0) := (others => '0');
  signal wdata : std_logic_vector(7 downto 0) := (others => '0');
  signal raddr : unsigned(16 downto 0) := (others => '0');
  signal rdata : std_logic_vector(7 downto 0);
  signal done  : boolean := false;
begin
  clk <= not clk after T/2 when not done else '0';

  dut : entity work.framebuffer
    port map (clk => clk, we => we, waddr => waddr, wdata => wdata,
              raddr => raddr, rdata => rdata);

  stim : process
    -- all stimulus is driven 1 ns after a rising edge
    procedure write_px(a : natural; d : std_logic_vector(7 downto 0)) is
    begin
      we <= '1'; waddr <= to_unsigned(a, 17); wdata <= d;
      wait until rising_edge(clk); wait for 1 ns;
      we <= '0';
    end procedure;

    -- Set raddr, confirm rdata has NOT changed yet (no combinational path),
    -- then confirm the new data shows up after exactly one clock edge.
    procedure read_check(a : natural; exp : std_logic_vector(7 downto 0)) is
      variable before : std_logic_vector(7 downto 0);
    begin
      before := rdata;
      raddr <= to_unsigned(a, 17);
      wait for T/4;
      assert rdata = before
        report "rdata changed before clock edge (not registered)" severity failure;
      wait until rising_edge(clk); wait for 1 ns;
      assert rdata = exp
        report "addr " & integer'image(a) & ": expected " &
               integer'image(to_integer(unsigned(exp))) & ", got " &
               integer'image(to_integer(unsigned(rdata)))
        severity failure;
    end procedure;
  begin
    wait for 3 * T;
    wait until rising_edge(clk); wait for 1 ns;

    -- power-up contents are zero
    read_check(0, x"00");

    -- write a few addresses: first pixel, (x=1,y=0), start of row 1,
    -- middle, end of row 0, last pixel
    write_px(0,     x"E0");   -- red
    write_px(1,     x"1C");   -- green
    write_px(320,   x"03");   -- blue, (x=0,y=1)
    write_px(319,   x"FF");   -- white, end of row 0
    write_px(38400, x"A5");   -- middle
    write_px(LAST,  x"5A");   -- last pixel (x=319,y=239)

    -- read back
    read_check(0,     x"E0");
    read_check(1,     x"1C");
    read_check(320,   x"03");
    read_check(319,   x"FF");
    read_check(38400, x"A5");
    read_check(LAST,  x"5A");
    read_check(2,     x"00");   -- untouched address still zero

    -- back-to-back reads: one new pixel per clock, pipelined
    raddr <= to_unsigned(0, 17);
    wait until rising_edge(clk); wait for 1 ns;
    assert rdata = x"E0" report "pipelined read 0 failed" severity failure;
    raddr <= to_unsigned(1, 17);
    wait until rising_edge(clk); wait for 1 ns;
    assert rdata = x"1C" report "pipelined read 1 failed" severity failure;
    raddr <= to_unsigned(LAST, 17);
    wait until rising_edge(clk); wait for 1 ns;
    assert rdata = x"5A" report "pipelined read LAST failed" severity failure;

    -- write and read same address in the same cycle: read-first (old data)
    we <= '1'; waddr <= to_unsigned(LAST, 17); wdata <= x"77";
    raddr <= to_unsigned(LAST, 17);
    wait until rising_edge(clk); wait for 1 ns;
    we <= '0';
    assert rdata = x"5A" report "read-during-write should return old data" severity failure;
    read_check(LAST, x"77");

    report "framebuffer_tb: ALL TESTS PASSED" severity note;
    done <= true;
    wait;
  end process;
end architecture;

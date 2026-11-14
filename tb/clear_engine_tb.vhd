-- Testbench for clear_engine, wired to the real framebuffer so the final
-- memory contents are checked as well as the write stream. The memory side is a
-- stand-in: mem_ready rises late and mem_req_ready stalls one clock in three.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.qogpu_pkg.all;

entity clear_engine_tb is
end entity;

architecture sim of clear_engine_tb is
  constant T     : time    := 10 ns;
  constant NPIX  : natural := FB_PIXELS;

  signal clk, rst_n : std_logic := '0';
  signal start      : std_logic := '0';
  signal color_in   : pixel_t := (others => '0');
  signal busy, done : std_logic;
  signal we         : std_logic;
  signal waddr      : fb_addr_t;
  signal wdata      : pixel_t;
  signal depth_in   : std_logic_vector(7 downto 0) := (others => '0');
  signal exp_depth  : std_logic_vector(7 downto 0) := (others => '0');
  signal mem_ready  : std_logic := '0';
  signal req_valid, req_ready, req_we : std_logic;
  signal req_addr   : fb_addr_t;
  signal req_wdata  : std_logic_vector(7 downto 0);
  signal stall_cnt  : natural range 0 to 2 := 0;
  signal raddr      : fb_addr_t := (others => '0');
  signal rdata      : pixel_t;

  -- expectations / monitor results
  signal exp_color   : std_logic_vector(7 downto 0) := (others => '0');
  signal done_count  : natural := 0;
  signal write_total : natural := 0;
  signal finished    : boolean := false;
begin
  clk <= not clk after T/2 when not finished else '0';

  eng : entity work.clear_engine
    generic map (DEPTH_W => 8)
    port map (clk_i => clk, rst_n_i => rst_n, start_i => start, color_i => color_in,
              depth_i => depth_in,
              busy_o => busy, done_o => done, fb_we_o => we, fb_waddr_o => waddr,
              fb_wdata_o => wdata,
              mem_ready_i => mem_ready, mem_req_valid_o => req_valid,
              mem_req_ready_i => req_ready, mem_req_we_o => req_we,
              mem_req_addr_o => req_addr, mem_req_wdata_o => req_wdata);

  process (clk)
  begin
    if rising_edge(clk) then
      if rst_n = '0' then
        stall_cnt <= 0;
      elsif stall_cnt = 2 then
        stall_cnt <= 0;
      else
        stall_cnt <= stall_cnt + 1;
      end if;
    end if;
  end process;
  req_ready <= '1' when stall_cnt /= 2 else '0';

  process (clk)
    variable cnt : natural := 0;
  begin
    if rising_edge(clk) then
      if rst_n = '0' then
        cnt := 0;
        mem_ready <= '0';
      elsif cnt = 40 then
        mem_ready <= '1';
      else
        cnt := cnt + 1;
      end if;
    end if;
  end process;

  fb : entity work.framebuffer
    port map (clk_i => clk, wr_en_i => we, wr_addr_i => waddr, wr_data_i => wdata,
              rd_addr_i => raddr, rd_data_o => rdata);

  -- Monitor: samples every clock edge and checks the write stream.
  monitor : process (clk)
    variable n         : natural := 0;
    variable done_prev : std_logic := '0';
  begin
    if rising_edge(clk) and rst_n = '1' then
      assert not (req_valid = '1' and mem_ready = '0')
        report "request before mem_ready" severity failure;
      assert req_we = '1' report "clear request is not a write" severity failure;
      if req_valid = '1' and req_ready = '1' then
        assert req_wdata = exp_depth report "bad depth word" severity failure;
      end if;
      assert we = (req_valid and req_ready)
        report "fb write not locked to the accepted depth write" severity failure;
      if we = '1' then
        assert busy = '1' report "we high while busy low" severity failure;
        assert req_addr = waddr report "depth and color addresses differ" severity failure;
        assert n < NPIX report "more than 76800 writes in one clear" severity failure;
        assert waddr = to_unsigned(n, FB_ADDR_W)
          report "bad address: expected " & integer'image(n) &
                 ", got " & integer'image(to_integer(waddr)) severity failure;
        assert wdata = exp_color
          report "bad color at address " & integer'image(n) severity failure;
        n := n + 1;
        write_total <= write_total + 1;
      end if;
      if done = '1' then
        assert n = NPIX
          report "done after " & integer'image(n) & " writes, expected 76800" severity failure;
        assert we = '0' report "we high during done" severity failure;
        assert done_prev = '0' report "done lasted more than one cycle" severity failure;
        done_count <= done_count + 1;
        n := 0;
      end if;
      done_prev := done;
    end if;
  end process;

  stim : process
    procedure pulse_start is
    begin
      start <= '1';
      wait until rising_edge(clk); wait for 1 ns;
      start <= '0';
    end procedure;

    procedure wait_done is
    begin
      wait until done = '1' for 4 ms;
      assert done = '1' report "timeout waiting for done" severity failure;
      wait until rising_edge(clk); wait for 1 ns;   -- done pulse has ended
    end procedure;

    -- read every pixel back (pipelined, 1-cycle latency) and compare
    procedure verify_all(c : std_logic_vector(7 downto 0)) is
    begin
      for i in 0 to NPIX loop
        if i < NPIX then
          raddr <= to_unsigned(i, FB_ADDR_W);
        end if;
        wait until rising_edge(clk); wait for 1 ns;
        if i > 0 then
          assert rdata = c
            report "framebuffer mismatch at address " & integer'image(i - 1)
            severity failure;
        end if;
      end loop;
    end procedure;
  begin
    -- reset
    rst_n <= '0';
    wait for 3 * T;
    wait until rising_edge(clk); wait for 1 ns;
    rst_n <= '1';
    wait until rising_edge(clk); wait for 1 ns;

    -- idle: nothing happens without start
    assert busy = '0' and we = '0' and done = '0'
      report "engine not idle after reset" severity failure;
    for i in 1 to 20 loop
      wait until rising_edge(clk); wait for 1 ns;
    end loop;
    assert write_total = 0 report "writes without start" severity failure;

    -- clear #1: color E0
    color_in <= x"E0"; exp_color <= x"E0";
    depth_in <= x"FF"; exp_depth <= x"FF";
    wait until mem_ready = '1';
    wait until rising_edge(clk); wait for 1 ns;
    pulse_start;
    assert busy = '1' report "busy not high after start" severity failure;
    wait_done;
    for i in 1 to 10 loop
      wait until rising_edge(clk); wait for 1 ns;
    end loop;
    assert done_count = 1 report "done did not pulse exactly once (clear 1)" severity failure;
    assert write_total = NPIX report "wrong write count (clear 1)" severity failure;
    assert busy = '0' and we = '0' report "engine not idle after clear 1" severity failure;
    verify_all(x"E0");

    -- clear #2: color 1C; start pulse and color change mid-run must be ignored
    color_in <= x"1C"; exp_color <= x"1C";
    depth_in <= x"40"; exp_depth <= x"40";
    pulse_start;
    for i in 1 to 100 loop
      wait until rising_edge(clk); wait for 1 ns;
    end loop;
    color_in <= x"FF"; depth_in <= x"00";
    pulse_start;                       -- ignored: engine is busy
    assert busy = '1' report "busy dropped on extra start" severity failure;
    wait_done;
    for i in 1 to 10 loop
      wait until rising_edge(clk); wait for 1 ns;
    end loop;
    assert done_count = 2 report "done did not pulse exactly once (clear 2)" severity failure;
    assert write_total = 2 * NPIX report "wrong write count (clear 2)" severity failure;
    verify_all(x"1C");

    report "clear_engine_tb: ALL TESTS PASSED" severity note;
    finished <= true;
    wait;
  end process;
end architecture;

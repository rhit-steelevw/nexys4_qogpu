library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use std.textio.all;

entity tb_writeback is
  generic (DW : natural := 8);   -- depth width, set with -generic_top DW=16 in xelab
end entity;

architecture sim of tb_writeback is
  constant N : natural := 40;   -- phase 1 fragments
  constant NT : natural := N + 1; -- plus one fragment for the reset test
  signal clk : std_logic := '0';
  signal rst_n : std_logic := '0';
  signal pass_valid, pass_ready : std_logic := '0';
  signal pass_x : unsigned(8 downto 0) := (others => '0');
  signal pass_y : unsigned(7 downto 0) := (others => '0');
  signal pass_z : unsigned(DW-1 downto 0) := (others => '0');
  signal pass_color : std_logic_vector(7 downto 0) := (others => '0');
  signal fb_we, mem_req_valid, mem_req_we : std_logic;
  signal fb_waddr, mem_req_addr : unsigned(16 downto 0);
  signal fb_wdata : std_logic_vector(7 downto 0);
  signal mem_req_wdata : std_logic_vector(DW-1 downto 0);
  signal mem_req_ready : std_logic;
  signal stall_cnt : integer := 0;
  signal fb_n, mem_n : natural := 0;
  signal fb_skip : natural := 0;   -- fb writes of a fragment aborted by reset
  signal force_stall : std_logic := '0';
  signal pass_kill, pass_eot, pass_eof : std_logic := '0';
  signal tri_done, frame_done : std_logic;
  signal ph3 : boolean := false;
  signal tri_cnt, frm_cnt, both_cnt, p3_fb, p3_mem : natural := 0;

  -- fragment i: corners first/last, scattered in between
  function fx(i : natural) return natural is
  begin
    if i = 0 then return 0; elsif i = N-1 then return 319; else return (i*37) mod 320; end if;
  end function;
  function fy(i : natural) return natural is
  begin
    if i = 0 then return 0; elsif i = N-1 then return 239; else return (i*13) mod 240; end if;
  end function;
  function fz(i : natural) return natural is begin return (i*7+3) mod (2**DW); end function;
  function fc(i : natural) return natural is begin return (i*11+5) mod 256; end function;
  function faddr(i : natural) return natural is begin return fy(i)*320 + fx(i); end function;
begin
  clk <= not clk after 5 ns;
  mem_req_ready <= '1' when stall_cnt = 0 and force_stall = '0' else '0';

  dut : entity work.writeback
    generic map (DEPTH_W => DW)
    port map (clk, rst_n, pass_valid, pass_ready, pass_x, pass_y, pass_z, pass_color,
              fb_we, fb_waddr, fb_wdata,
              mem_req_valid, mem_req_ready, mem_req_we, mem_req_addr, mem_req_wdata,
              pass_kill, pass_eot, pass_eof, tri_done, frame_done);

  counters : process (clk)
  begin
    if rising_edge(clk) then
      if tri_done = '1' then tri_cnt <= tri_cnt + 1; end if;
      if frame_done = '1' then frm_cnt <= frm_cnt + 1; end if;
      if tri_done = '1' and frame_done = '1' then both_cnt <= both_cnt + 1; end if;
      if ph3 and fb_we = '1' then p3_fb <= p3_fb + 1; end if;
      if ph3 and mem_req_valid = '1' and mem_req_ready = '1' then p3_mem <= p3_mem + 1; end if;
    end if;
  end process;

  -- Memory controller stall model: first 10 requests immediate, then 1..7 cycle stalls
  process (clk)
  begin
    if rising_edge(clk) then
      if mem_req_valid = '1' and mem_req_ready = '1' then
        if mem_n < 10 then stall_cnt <= 0; else stall_cnt <= ((mem_n*3) mod 7) + 1; end if;
      elsif mem_req_valid = '1' and stall_cnt > 0 then
        stall_cnt <= stall_cnt - 1;
      end if;
    end if;
  end process;

  -- Monitors: check every write, in order
  process (clk)
    file dump : text open write_mode is "fb_dump.txt";
    variable l : line;
    variable fi : integer;
  begin
    if rising_edge(clk) then
      if fb_we = '1' and not ph3 then
        fi := fb_n - fb_skip;
        assert fi < NT report "extra framebuffer write" severity failure;
        assert to_integer(fb_waddr) = faddr(fi)
          report "fb addr mismatch #" & integer'image(fi) severity failure;
        assert to_integer(unsigned(fb_wdata)) = fc(fi)
          report "fb color mismatch #" & integer'image(fi) severity failure;
        -- frame dump for RQ-90 comparison: "x y color"
        write(l, integer'image(to_integer(fb_waddr) mod 320) & " " &
                 integer'image(to_integer(fb_waddr) / 320) & " " & to_hstring(fb_wdata));
        writeline(dump, l);
        fb_n <= fb_n + 1;
      end if;
      if mem_req_valid = '1' and mem_req_ready = '1' and not ph3 then
        assert mem_n < NT report "extra depth write" severity failure;
        assert mem_req_we = '1' report "depth request not a write" severity failure;
        assert to_integer(mem_req_addr) = faddr(mem_n)
          report "depth addr mismatch #" & integer'image(mem_n) severity failure;
        assert to_integer(unsigned(mem_req_wdata)) = fz(mem_n)
          report "depth value mismatch #" & integer'image(mem_n) severity failure;
        mem_n <= mem_n + 1;
      end if;
    end if;
  end process;

  -- Stimulus: back-to-back, with idle gaps every 5th fragment
  process
    variable t0, f0, b0 : natural;

    procedure present (kill, eot, eof : std_logic) is
    begin
      pass_x <= to_unsigned(10, 9); pass_y <= to_unsigned(20, 8);
      pass_z <= to_unsigned(30, DW);
      pass_color <= x"5A";
      pass_kill <= kill; pass_eot <= eot; pass_eof <= eof;
      pass_valid <= '1';
    end procedure;

    procedure finish_present is
    begin
      loop
        wait until rising_edge(clk);
        exit when pass_ready = '1';
      end loop;
      pass_valid <= '0'; pass_kill <= '0'; pass_eot <= '0'; pass_eof <= '0';
    end procedure;

    procedure idle (n : natural) is
    begin
      for g in 1 to n loop wait until rising_edge(clk); end loop;
    end procedure;
  begin
    wait for 52 ns;
    rst_n <= '1';
    wait until rising_edge(clk);
    for i in 0 to N-1 loop
      pass_x <= to_unsigned(fx(i), 9);
      pass_y <= to_unsigned(fy(i), 8);
      pass_z <= to_unsigned(fz(i), DW);
      pass_color <= std_logic_vector(to_unsigned(fc(i), 8));
      pass_valid <= '1';
      loop
        wait until rising_edge(clk);
        exit when pass_ready = '1';   -- sampled pre-edge: handshake done
      end loop;
      if i mod 5 = 4 then
        pass_valid <= '0';
        for g in 1 to 3 loop wait until rising_edge(clk); end loop;
      end if;
    end loop;
    pass_valid <= '0';
    for g in 1 to 20 loop wait until rising_edge(clk); end loop;
    assert fb_n = N and mem_n = N
      report "phase 1 count mismatch: fb=" & integer'image(fb_n) & " mem=" & integer'image(mem_n)
      severity failure;

    -- Phase 2: reset while the controller is stalling. The request must be
    -- held until reset, and reset must clear it and free the input.
    force_stall <= '1';
    pass_x <= to_unsigned(fx(N), 9);
    pass_y <= to_unsigned(fy(N), 8);
    pass_z <= to_unsigned(fz(N), DW);
    pass_color <= std_logic_vector(to_unsigned(fc(N), 8));
    pass_valid <= '1';
    loop
      wait until rising_edge(clk);
      exit when pass_ready = '1';
    end loop;
    pass_valid <= '0';
    for g in 1 to 8 loop
      wait until rising_edge(clk);
      assert mem_req_valid = '1' report "request dropped while stalled" severity failure;
      assert pass_ready = '0' report "ready while a request is pending" severity failure;
    end loop;
    rst_n <= '0'; fb_skip <= 1;
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    assert mem_req_valid = '0' and fb_we = '0' and pass_ready = '1'
      report "reset did not clear the pipeline" severity failure;
    rst_n <= '1'; force_stall <= '0';
    wait until rising_edge(clk);
    -- resend the same fragment after reset
    pass_valid <= '1';
    loop
      wait until rising_edge(clk);
      exit when pass_ready = '1';
    end loop;
    pass_valid <= '0';
    for g in 1 to 20 loop wait until rising_edge(clk); end loop;
    assert fb_n - fb_skip = NT and mem_n = NT
      report "final count mismatch: fb=" & integer'image(fb_n - fb_skip) & " mem=" & integer'image(mem_n)
      severity failure;

    -- Phase 3: markers, tri_done / frame_done (H2/H3)
    ph3 <= true;
    idle(2);

    -- killed eot: one-clock transfer, no writes, done pulse on the next cycle
    t0 := tri_cnt;
    present('1', '1', '0');
    wait until rising_edge(clk);
    assert pass_ready = '1' report "killed marker not taken in one clock" severity failure;
    pass_valid <= '0'; pass_kill <= '0'; pass_eot <= '0';
    wait for 1 ns;
    assert tri_done = '1' and frame_done = '0' report "tri_done not pulsed after killed eot" severity failure;
    idle(5);
    assert tri_cnt = t0 + 1 report "tri_done count wrong after killed eot" severity failure;
    assert p3_fb = 0 and p3_mem = 0 report "killed marker wrote something" severity failure;

    -- passing eot with the depth write stalled: tri_done only after the accept
    t0 := tri_cnt;
    force_stall <= '1';
    present('0', '1', '0');
    finish_present;
    for g in 1 to 10 loop
      wait until rising_edge(clk);
      assert tri_done = '0' report "tri_done before the depth write was accepted" severity failure;
      assert mem_req_valid = '1' report "depth request dropped while stalled" severity failure;
    end loop;
    force_stall <= '0';
    idle(15);
    assert tri_cnt = t0 + 1 report "tri_done did not pulse exactly once" severity failure;
    assert p3_mem = 1 and p3_fb = 1 report "passing eot write count wrong" severity failure;

    -- killed eot behind a stalled write: not taken until the write is accepted
    t0 := tri_cnt;
    force_stall <= '1';
    present('0', '0', '0');
    finish_present;
    present('1', '1', '0');
    for g in 1 to 6 loop
      wait until rising_edge(clk);
      assert pass_ready = '0' report "killed eot taken while a write is pending" severity failure;
      assert tri_done = '0' report "tri_done while a write is pending" severity failure;
    end loop;
    force_stall <= '0';
    finish_present;
    idle(15);
    assert tri_cnt = t0 + 1 report "tri_done missing after stalled write" severity failure;

    -- eot and eof together: both pulses on the same cycle
    t0 := tri_cnt; f0 := frm_cnt; b0 := both_cnt;
    present('0', '1', '1');
    finish_present;
    idle(15);
    assert tri_cnt = t0 + 1 and frm_cnt = f0 + 1 and both_cnt = b0 + 1
      report "eot+eof pulses wrong (written fragment)" severity failure;
    present('1', '1', '1');
    finish_present;
    idle(5);
    assert tri_cnt = t0 + 2 and frm_cnt = f0 + 2 and both_cnt = b0 + 2
      report "eot+eof pulses wrong (killed fragment)" severity failure;

    report "tb_writeback: ALL TESTS PASSED (" & integer'image(NT) & " fragments + reset-while-stalled)";
    finish;
  end process;
end architecture;

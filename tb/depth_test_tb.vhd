-- depth_test_tb.vhd : self-checking testbench for depth_test (VHDL-2008, xsim)
-- Runs 6 configurations back to back: read latency {1, 3, random 10..40}
-- x mem_req_ready {always high, random low stretches}. In stall mode
-- pass_ready is randomized too. Each config uses its own pixels (depth
-- memory starts at all-ones = far plane).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity depth_test_tb is
end entity;

architecture sim of depth_test_tb is
  constant DEPTH_W  : natural := 8;
  constant CLK_P    : time    := 10 ns;
  constant MEM_SIZE : natural := 81920;
  type mem_t is array (0 to MEM_SIZE-1) of unsigned(DEPTH_W-1 downto 0);

  signal mem : mem_t := (others => (others => '1'));  -- written only by E6 model

  signal clk   : std_logic := '0';
  signal rst_n : std_logic := '0';

  signal frag_valid, frag_ready : std_logic := '0';
  signal px : unsigned(8 downto 0) := (others => '0');
  signal py : unsigned(7 downto 0) := (others => '0');
  signal pz : unsigned(DEPTH_W-1 downto 0) := (others => '0');
  signal pu, pv : unsigned(7 downto 0) := (others => '0');

  signal mem_req_valid, mem_req_ready : std_logic;
  signal mem_req_addr : unsigned(16 downto 0);
  signal mem_rsp_valid : std_logic := '0';
  signal mem_rsp_data  : std_logic_vector(DEPTH_W-1 downto 0) := (others => '0');

  signal pass_valid : std_logic;
  signal pass_ready : std_logic := '1';
  signal pass_x : unsigned(8 downto 0);
  signal pass_y : unsigned(7 downto 0);
  signal pass_z : unsigned(DEPTH_W-1 downto 0);
  signal pass_u, pass_v : unsigned(7 downto 0);

  -- test controls
  signal lat_mode : natural := 0;        -- 0: 1 cycle, 1: 3 cycles, 2: random 10..40
  signal stall_en : boolean := false;
  signal done       : boolean := false;
  signal req_count  : natural := 0;       -- accepted memory requests
  signal lat_min    : natural := 1000;    -- latency range actually drawn (mode 2)
  signal lat_max    : natural := 0;
  signal busy       : std_logic := '0';
  signal ready_rand : std_logic := '1';

  -- E6 model results
  signal pass_count : natural := 0;
  signal last_x : unsigned(8 downto 0);
  signal last_y : unsigned(7 downto 0);
  signal last_z : unsigned(DEPTH_W-1 downto 0);
  signal last_u, last_v : unsigned(7 downto 0);
begin
  clk_gen : process
  begin
    while not done loop
      clk <= '0'; wait for CLK_P/2;
      clk <= '1'; wait for CLK_P/2;
    end loop;
    wait;
  end process;

  dut : entity work.depth_test
    generic map (DEPTH_W => DEPTH_W)
    port map (
      clk => clk, rst_n => rst_n,
      frag_valid => frag_valid, frag_ready => frag_ready,
      px => px, py => py, pz => pz, pu => pu, pv => pv,
      mem_req_valid => mem_req_valid, mem_req_ready => mem_req_ready,
      mem_req_addr => mem_req_addr,
      mem_rsp_valid => mem_rsp_valid, mem_rsp_data => mem_rsp_data,
      pass_valid => pass_valid, pass_ready => pass_ready,
      pass_x => pass_x, pass_y => pass_y, pass_z => pass_z, pass_u => pass_u, pass_v => pass_v,
      wr_pending => '0');

  ---------------------------------------------------------------------------
  -- Memory-controller model: one outstanding read, configurable latency.
  -- Response is seen by the DUT exactly LAT edges after the accept edge.
  ---------------------------------------------------------------------------
  mem_req_ready <= '1' when (ready_rand = '1' and busy = '0') else '0';

  mem_model : process (clk)
    variable s1 : positive := 11;
    variable s2 : positive := 22;
    variable r  : real;
    variable cnt : integer := 0;
    variable a   : natural := 0;
    variable lat : integer;
  begin
    if rising_edge(clk) then
      mem_rsp_valid <= '0';
      if rst_n = '0' then                 -- system reset also resets the controller
        busy <= '0';
      elsif busy = '1' then
        cnt := cnt - 1;
        if cnt = 0 then
          mem_rsp_valid <= '1';
          mem_rsp_data  <= std_logic_vector(mem(a));
          busy <= '0';
        end if;
      elsif mem_req_valid = '1' and mem_req_ready = '1' then
        assert to_integer(mem_req_addr) < MEM_SIZE
          report "request address out of range" severity failure;
        a := to_integer(mem_req_addr);
        req_count <= req_count + 1;
        case lat_mode is
          when 0 => lat := 1;
          when 1 => lat := 3;
          when others =>
            uniform(s1, s2, r);
            lat := 10 + integer(floor(r * 31.0));   -- 10..40
        end case;
        if lat_mode = 2 then
          if lat < lat_min then lat_min <= lat; end if;
          if lat > lat_max then lat_max <= lat; end if;
        end if;
        if lat = 1 then
          mem_rsp_valid <= '1';
          mem_rsp_data  <= std_logic_vector(mem(a));
        else
          busy <= '1';
          cnt  := lat - 1;
        end if;
      end if;
    end if;
  end process;

  -- random mem_req_ready stretches (refresh-like): low up to 30 cycles
  ready_gen : process (clk)
    variable s1 : positive := 33;
    variable s2 : positive := 44;
    variable r  : real;
    variable cnt : integer := 0;
  begin
    if rising_edge(clk) then
      if not stall_en then
        ready_rand <= '1';
        cnt := 0;
      elsif cnt <= 0 then
        uniform(s1, s2, r);
        if ready_rand = '1' then
          ready_rand <= '0';
          cnt := 1 + integer(floor(r * 30.0));
        else
          ready_rand <= '1';
          cnt := 1 + integer(floor(r * 3.0));
        end if;
      else
        cnt := cnt - 1;
      end if;
    end if;
  end process;

  -- random pass_ready in stall mode
  pass_ready_gen : process (clk)
    variable s1 : positive := 55;
    variable s2 : positive := 66;
    variable r  : real;
  begin
    if rising_edge(clk) then
      if stall_en then
        uniform(s1, s2, r);
        if r < 0.5 then pass_ready <= '0'; else pass_ready <= '1'; end if;
      else
        pass_ready <= '1';
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- E6 model: takes passed fragments, writes new depth to the depth memory
  ---------------------------------------------------------------------------
  e6_model : process (clk)
  begin
    if rising_edge(clk) then
      if pass_valid = '1' and pass_ready = '1' then
        mem(to_integer(pass_y) * 320 + to_integer(pass_x)) <= pass_z;
        pass_count <= pass_count + 1;
        last_x <= pass_x; last_y <= pass_y; last_z <= pass_z; last_u <= pass_u; last_v <= pass_v;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- Protocol checks: valid/data must stay stable until the handshake
  ---------------------------------------------------------------------------
  proto_chk : process (clk)
    variable p_rv, p_rr, p_pv, p_pr : std_logic := '0';
    variable p_addr : unsigned(16 downto 0) := (others => '0');
    variable p_x : unsigned(8 downto 0) := (others => '0');
    variable p_y : unsigned(7 downto 0) := (others => '0');
    variable p_z : unsigned(DEPTH_W-1 downto 0) := (others => '0');
    variable p_u, p_v : unsigned(7 downto 0) := (others => '0');
  begin
    if rising_edge(clk) and rst_n = '1' then
      if p_rv = '1' and p_rr = '0' then
        assert mem_req_valid = '1' and mem_req_addr = p_addr
          report "mem request dropped or changed before accepted" severity failure;
      end if;
      if p_pv = '1' and p_pr = '0' then
        assert pass_valid = '1' and pass_x = p_x and pass_y = p_y
               and pass_z = p_z and pass_u = p_u and pass_v = p_v
          report "pass_* dropped or changed before accepted" severity failure;
      end if;
    end if;
    if rising_edge(clk) then
      p_rv := mem_req_valid; p_rr := mem_req_ready; p_addr := mem_req_addr;
      p_pv := pass_valid;    p_pr := pass_ready;
      p_x := pass_x; p_y := pass_y; p_z := pass_z; p_u := pass_u; p_v := pass_v;
    end if;
  end process;

  -- watchdog
  watchdog : process
  begin
    wait until done for 50 ms;
    assert done report "TIMEOUT" severity failure;
    wait;
  end process;

  ---------------------------------------------------------------------------
  -- Stimulus / scoreboard
  ---------------------------------------------------------------------------
  stim : process
    variable s1 : positive := 7;
    variable s2 : positive := 9;
    variable r  : real;
    variable base : natural;
    variable rx, rz, gap : natural;
    variable rexp : boolean;

    -- send one fragment, wait until the DUT is idle again, check the outcome
    procedure send (x, y, z, c : natural; exp_pass : boolean) is
      variable before : natural;
    begin
      before := pass_count;
      frag_valid <= '1';
      px <= to_unsigned(x, 9); py <= to_unsigned(y, 8);
      pz <= to_unsigned(z, DEPTH_W); pu <= to_unsigned(c mod 256, 8); pv <= to_unsigned(255 - (c mod 256), 8);
      wait until rising_edge(clk) and frag_ready = '1';   -- accepted
      frag_valid <= '0';
      px <= (others => 'X'); py <= (others => 'X');
      pz <= (others => 'X'); pu <= (others => 'X'); pv <= (others => 'X');
      wait until rising_edge(clk) and frag_ready = '1';   -- back in IDLE
      if exp_pass then
        assert pass_count = before + 1
          report "fragment (" & integer'image(x) & "," & integer'image(y) & ") z="
                 & integer'image(z) & " should have PASSED" severity failure;
        assert last_x = x and last_y = y and last_z = z and last_u = c mod 256 and last_v = 255 - (c mod 256)
          report "pass_* payload mismatch" severity failure;
      else
        assert pass_count = before
          report "fragment (" & integer'image(x) & "," & integer'image(y) & ") z="
                 & integer'image(z) & " should have been DROPPED" severity failure;
      end if;
    end procedure;

    -- off-screen fragment: must be dropped and must not cause a memory read
    procedure send_off_screen (x, y : natural) is
      variable reads : natural;
    begin
      reads := req_count;
      send(x, y, 10, 16#EE#, false);
      assert req_count = reads
        report "off-screen fragment (" & integer'image(x) & "," & integer'image(y)
               & ") caused a memory read" severity failure;
    end procedure;

    -- reset while a read is in flight (memory controller is reset too),
    -- then check nothing leaks out and the DUT works again
    procedure reset_mid_read (x, y : natural) is
      variable before : natural;
    begin
      before := pass_count;
      frag_valid <= '1';
      px <= to_unsigned(x, 9); py <= to_unsigned(y, 8);
      pz <= to_unsigned(5, DEPTH_W); pu <= x"99"; pv <= x"66";
      wait until rising_edge(clk) and frag_ready = '1';   -- accepted
      frag_valid <= '0';
      wait until rising_edge(clk) and busy = '1';         -- read in flight
      rst_n <= '0';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      rst_n <= '1';
      for i in 1 to 60 loop wait until rising_edge(clk); end loop;  -- > max latency
      assert pass_count = before
        report "fragment passed after reset" severity failure;
      assert mem(y * 320 + x) = (DEPTH_W-1 downto 0 => '1')
        report "depth memory written after reset" severity failure;
      assert frag_ready = '1' report "DUT not idle after reset" severity failure;
    end procedure;

    procedure check_depth (x, y, z : natural) is
    begin
      assert mem(y * 320 + x) = to_unsigned(z, DEPTH_W)
        report "stored depth wrong at (" & integer'image(x) & "," & integer'image(y)
               & "): expected " & integer'image(z) severity failure;
    end procedure;
  begin
    rst_n <= '0';
    for i in 1 to 5 loop wait until rising_edge(clk); end loop;
    rst_n <= '1';
    wait until rising_edge(clk);

    for cfg in 0 to 5 loop
      lat_mode <= cfg mod 3;
      stall_en <= (cfg >= 3);
      base := 10 * cfg;
      report "config " & integer'image(cfg) & ": lat_mode=" & integer'image(cfg mod 3)
             & " stall=" & boolean'image(cfg >= 3);
      wait until rising_edge(clk);
      wait until rising_edge(clk);

      -- A: far first, then near -> both pass, near wins
      send(base+1, 5, 100, 16#AA#, true);
      send(base+1, 5,  50, 16#BB#, true);
      check_depth(base+1, 5, 50);
      -- B: near first, then far -> far dropped
      send(base+2, 6,  50, 16#CC#, true);
      send(base+2, 6, 100, 16#DD#, false);
      check_depth(base+2, 6, 50);
      -- C: equal depth keeps old pixel
      send(base+3, 7, 60, 16#11#, true);
      send(base+3, 7, 60, 16#22#, false);
      check_depth(base+3, 7, 60);
      -- D: z = max against far plane (all ones) is equal -> dropped
      send(base+4, 8, 255, 16#33#, false);
      -- E: z = 0 passes once, never again
      send(base+5, 9, 0, 16#44#, true);
      send(base+5, 9, 0, 16#55#, false);

      -- F: address-map corners, once
      if cfg = 0 then
        send(0,   0,   9, 16#01#, true);
        send(0,   0,   9, 16#02#, false);
        send(319, 239, 9, 16#03#, true);
        send(319, 239, 8, 16#04#, true);
        send(319, 239, 8, 16#05#, false);
        check_depth(319, 239, 8);
      end if;

      -- F2: off-screen fragments never reach memory
      send_off_screen(320, 0);     -- would alias to pixel (0,1)
      send_off_screen(0, 240);     -- first row past the frame
      send_off_screen(511, 255);   -- largest input values

      -- F3: reset in the middle of a read (random-latency configs only)
      if cfg mod 3 = 2 then
        reset_mid_read(base + 7, 13);
        send(base + 8, 13, 70, 16#77#, true);
        check_depth(base + 8, 13, 70);
      end if;

      -- G: random traffic on 4 pixels, scoreboard = depth memory
      for i in 1 to 150 loop
        uniform(s1, s2, r); rx := base + 6 + integer(floor(r * 4.0));
        uniform(s1, s2, r); rz := integer(floor(r * 256.0));
        rexp := to_unsigned(rz, DEPTH_W) < mem(12 * 320 + rx);
        send(rx, 12, rz, i mod 256, rexp);
        uniform(s1, s2, r); gap := integer(floor(r * 4.0));
        for g in 1 to gap loop wait until rising_edge(clk); end loop;
      end loop;
    end loop;

    assert lat_min <= 12 and lat_max >= 38 and lat_max <= 40 and lat_min >= 10
      report "random latency did not cover 10..40 (min=" & integer'image(lat_min)
             & " max=" & integer'image(lat_max) & ")" severity failure;
    report "latency range drawn: " & integer'image(lat_min) & ".." & integer'image(lat_max);
    report "ALL TESTS PASSED (6 configs)" severity note;
    done <= true;
    wait;
  end process;
end architecture;

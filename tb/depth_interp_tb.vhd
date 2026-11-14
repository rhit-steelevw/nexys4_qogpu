-- depth_interp_tb: E3 (RQ-93) against the Ada golden vectors
--   setup.csv rows 1..8 -> z0..z2, area2 per triangle (raster_tb_pkg)
--   edge.csv covered rows -> scan_t input (E values as the Ada computed them)
--   interp.csv -> expected depth, same order as the covered rows of edge.csv
-- Run "make vectors" first. INTERP = true, DEPTH_W = 8 (Ada Interp_Z is D = 8).
--
-- out_ready is low 3 of every 7 clocks, and the output must hold while stalled.
-- Also checks: reset in the middle of a division, a killed row without eot/eof is dropped (no output); a killed
-- row with eot is sent with kill = 1.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.qogpu_pkg.all;
use work.raster_pkg.all;
use work.raster_tb_pkg.all;

entity depth_interp_tb is
end entity;

architecture sim of depth_interp_tb is
  constant CLK_PERIOD : time := 10 ns;

  signal clk   : std_logic := '0';
  signal rst_n : std_logic := '0';
  signal done  : boolean := false;

  signal in_valid, in_ready : std_logic := '0';
  signal in_scan            : scan_t := SCAN_ZERO;
  signal out_valid, out_ready : std_logic := '0';
  signal o_px   : fb_x_t;
  signal o_py   : fb_y_t;
  signal o_z    : unsigned(7 downto 0);
  signal o_kill, o_eot, o_eof : std_logic;
  signal o_color : pixel_t;
  signal cyc : natural := 0;
begin
  clk <= not clk after CLK_PERIOD / 2 when not done;

  dut : entity work.depth_interp
    generic map (DEPTH_W => 8, INTERP => true)
    port map (
      clk_i => clk, rst_n_i => rst_n,
      in_valid_i => in_valid, in_ready_o => in_ready, in_scan_i => in_scan,
      out_valid_o => out_valid, out_ready_i => out_ready,
      out_px_o => o_px, out_py_o => o_py, out_z_o => o_z,
      out_kill_o => o_kill, out_eot_o => o_eot, out_eof_o => o_eof,
      out_color_o => o_color
    );

  process (clk)
  begin
    if rising_edge(clk) then
      cyc <= cyc + 1;
    end if;
  end process;
  out_ready <= '0' when (cyc mod 7) < 3 else '1';

  stable_check : process (clk)
    type out_t is record
      px : fb_x_t; py : fb_y_t; z : unsigned(7 downto 0);
      kill, eot, eof : std_logic; color : pixel_t;
    end record;
    variable prev, cur : out_t;
    variable held : boolean := false;
  begin
    if rising_edge(clk) then
      cur := (o_px, o_py, o_z, o_kill, o_eot, o_eof, o_color);
      if held then
        assert cur = prev
          report "depth_interp_tb: output changed while stalled" severity failure;
      end if;
      held := out_valid = '1' and out_ready = '0' and rst_n = '1';
      prev := cur;
    end if;
  end process;

  watchdog : process
  begin
    wait for 50 ms;
    if not done then
      report "FAIL: depth_interp_tb timed out" severity failure;
    end if;
    wait;
  end process;

  stim : process
    file fs, fe, fz : text;
    variable ls, le, lz : line;
    variable ok, ok_z : boolean;
    variable rows, errors : natural := 0;

    type tri_tab_t is array (1 to 8) of tri_t;
    variable tris : tri_tab_t;
    variable t    : tri_t;
    variable n_tri, n_e, n_z : integer;
    variable epx, zpx : fb_x_t;
    variable epy, zpy : fb_y_t;
    variable ee   : e_arr3_t;
    variable ecov : std_logic;
    variable zexp : unsigned(7 downto 0);
    variable s    : scan_t;
    variable first_s : scan_t;
    variable first_z : unsigned(7 downto 0);
    variable have_first : boolean := false;

    procedure fail(msg : string) is
    begin
      if errors < 10 then
        report msg severity error;
      end if;
      errors := errors + 1;
    end procedure;

    procedure send(x : scan_t) is
    begin
      in_scan <= x; in_valid <= '1';
      wait until rising_edge(clk) and in_ready = '1';
      in_valid <= '0';
    end procedure;
  begin
    rst_n <= '0';
    wait for 5 * CLK_PERIOD;
    wait until rising_edge(clk);
    rst_n <= '1';

    file_open(fs, "setup.csv", read_mode);
    for k in 1 to 8 loop
      next_data_line(fs, ls, ok);
      read_setup_row(ls, n_tri, t);
      tris(n_tri) := t;
    end loop;
    file_close(fs);

    file_open(fe, "edge.csv", read_mode);
    file_open(fz, "interp.csv", read_mode);
    next_data_line(fe, le, ok);
    if not ok then
      report "FAIL: edge.csv is empty. Run make vectors" severity failure;
    end if;
    while ok loop
      read_edge_row(le, n_e, epx, epy, ee, ecov);
      if ecov = '1' then
        t := tris(n_e);
        s := SCAN_ZERO;
        s.px := epx; s.py := epy; s.e := ee;
        s.z := t.z; s.area2 := t.area2; s.color := t.color;
        if not have_first then
          first_s := s;
        end if;
        send(s);
        wait until rising_edge(clk) and out_valid = '1' and out_ready = '1';

        next_data_line(fz, lz, ok_z);
        read_interp_row(lz, n_z, zpx, zpy, zexp);
        rows := rows + 1;
        if not have_first then
          first_z := zexp;
          have_first := true;
        end if;
        if not ok_z or o_px /= zpx or o_py /= zpy or n_z /= n_e then
          fail("tri " & integer'image(n_e) & ": pixel mismatch with interp.csv");
        end if;
        if o_z /= zexp then
          fail("tri " & integer'image(n_e) & " (" & integer'image(to_integer(epx)) & "," &
               integer'image(to_integer(epy)) & "): z = " & to_hstring(std_logic_vector(o_z)) &
               ", Ada says " & to_hstring(std_logic_vector(zexp)));
        end if;
        if o_kill /= '0' or o_color /= t.color then
          fail("tri " & integer'image(n_e) & ": kill or color wrong");
        end if;
      end if;
      next_data_line(fe, le, ok);
    end loop;
    file_close(fe);
    file_close(fz);

    -- reset in the middle of a division, then the same fragment again
    send(first_s);
    for k in 1 to 6 loop
      wait until rising_edge(clk);
    end loop;
    if in_ready /= '0' then
      fail("reset test: fragment finished before the reset");
    end if;
    rst_n <= '0';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst_n <= '1';
    wait until rising_edge(clk);
    if out_valid /= '0' or in_ready /= '1' then
      fail("reset test: DUT not idle after reset");
    end if;
    send(first_s);
    wait until rising_edge(clk) and out_valid = '1' and out_ready = '1';
    if o_z /= first_z then
      fail("reset test: z wrong after reset");
    end if;

    -- killed without eot/eof: accepted, nothing comes out
    s := SCAN_ZERO;
    s.kill := '1';
    send(s);
    for k in 1 to 20 loop
      wait until rising_edge(clk);
      if out_valid /= '0' then
        fail("drop: out_valid rose for a killed pixel");
      end if;
    end loop;
    if in_ready /= '1' then
      fail("drop: in_ready did not return to '1'");
    end if;

    -- killed with eot and eof: marker goes through
    s := SCAN_ZERO;
    s.kill := '1'; s.eot := '1'; s.eof := '1'; s.color := x"5A";
    s.px := to_unsigned(7, FB_X_W); s.py := to_unsigned(9, FB_Y_W);
    send(s);
    wait until rising_edge(clk) and out_valid = '1' and out_ready = '1';
    if o_kill /= '1' or o_eot /= '1' or o_eof /= '1' or o_color /= x"5A" or
       o_px /= 7 or o_py /= 9 then
      fail("marker: wrong output");
    end if;

    if errors = 0 and rows > 0 then
      report "depth_interp_tb: " & integer'image(rows) & " depths bit-exact with the Ada reference";
      report "depth_interp_tb: ALL TESTS PASSED";
    else
      report "FAIL: errors=" & integer'image(errors) & " rows=" & integer'image(rows)
        severity failure;
    end if;
    done <= true;
    wait;
  end process;
end architecture;

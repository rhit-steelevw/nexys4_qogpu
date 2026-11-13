-- raster_scan_tb: E1 + E2 (RQ-93) against the Ada golden vectors
--   setup.csv rows 1..8 -> tri_t (raster_tb_pkg), edge.csv -> expected pixels.
-- Run "make vectors" first: edge.csv is generated, not committed.
--
-- Per triangle, edge.csv rows are row-major over the bounding box plus a
-- 1-pixel margin. Rows outside the box are not emitted by the DUT; they are
-- skipped but must have covered = 0. Rows inside the box are compared with
-- DUT output n, in order: px, py, E0..E2, kill = not covered.
-- Tri 7 (empty, sent with last = 1): exactly one marker, kill = eot = eof = 1.
-- Back-pressure: out_ready is low 3 of every 7 clocks for the whole run.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.qogpu_pkg.all;
use work.raster_pkg.all;
use work.raster_tb_pkg.all;

entity raster_scan_tb is
end entity;

architecture sim of raster_scan_tb is
  constant CLK_PERIOD : time := 10 ns;
  constant N_DIRECTED : natural := 8;      -- directed triangles in edge.csv

  signal clk   : std_logic := '0';
  signal rst_n : std_logic := '0';
  signal done  : boolean := false;
  signal cyc   : natural := 0;

  signal in_valid, in_ready : std_logic := '0';
  signal in_tri             : tri_t := TRI_ZERO;
  signal out_valid, out_ready : std_logic := '0';
  signal scan               : scan_t;
begin
  clk <= not clk after CLK_PERIOD / 2 when not done;

  -- stall pattern: ready low on 3 of every 7 clocks
  process (clk)
  begin
    if rising_edge(clk) then
      cyc <= cyc + 1;
    end if;
  end process;
  out_ready <= '0' when (cyc mod 7) < 3 else '1';

  dut : entity work.raster_scan
    port map (
      clk_i => clk, rst_n_i => rst_n,
      in_valid_i => in_valid, in_ready_o => in_ready, in_tri_i => in_tri,
      out_valid_o => out_valid, out_ready_i => out_ready, out_scan_o => scan
    );

  -- the payload must hold while valid and not ready
  stable_check : process (clk)
    variable prev : scan_t;
    variable held : boolean := false;
  begin
    if rising_edge(clk) then
      if held then
        assert scan = prev
          report "raster_scan_tb: out_scan_o changed while stalled" severity failure;
      end if;
      held := out_valid = '1' and out_ready = '0';
      prev := scan;
    end if;
  end process;

  watchdog : process
  begin
    wait for 50 ms;
    if not done then
      report "FAIL: raster_scan_tb timed out" severity failure;
    end if;
    wait;
  end process;

  stim : process
    file fs, fe : text;
    variable ls, le : line;
    variable ok_s, ok_e : boolean;
    variable n_tri, n_e : integer;
    variable t : tri_t;
    variable epx : fb_x_t;
    variable epy : fb_y_t;
    variable ee  : e_arr3_t;
    variable ecov : std_logic;
    variable is_eot : std_logic;
    variable pixels, expected, errors : natural := 0;

    procedure fail(msg : string) is
    begin
      if errors < 10 then
        report msg severity error;
      end if;
      errors := errors + 1;
    end procedure;

    procedure check_bit(n : integer; name : string; got, exp : std_logic) is
    begin
      if got /= exp then
        fail("tri " & integer'image(n) & ": " & name & " = " & std_logic'image(got) &
             ", expected " & std_logic'image(exp));
      end if;
    end procedure;
  begin
    rst_n <= '0';
    wait for 5 * CLK_PERIOD;
    wait until rising_edge(clk);
    rst_n <= '1';

    file_open(fs, "setup.csv", read_mode);
    file_open(fe, "edge.csv", read_mode);
    next_data_line(fe, le, ok_e);
    if not ok_e then
      report "FAIL: edge.csv is empty. Run make vectors" severity failure;
    end if;
    read_edge_row(le, n_e, epx, epy, ee, ecov);

    for k in 1 to N_DIRECTED loop
      next_data_line(fs, ls, ok_s);
      read_setup_row(ls, n_tri, t);

      in_tri <= t; in_valid <= '1';
      wait until rising_edge(clk) and in_ready = '1';
      in_valid <= '0';

      if t.empty = '1' then
        -- one marker pixel, then skip the all-zero rows of this triangle
        wait until rising_edge(clk) and out_valid = '1' and out_ready = '1';
        check_bit(n_tri, "marker kill", scan.kill, '1');
        check_bit(n_tri, "marker eot", scan.eot, '1');
        check_bit(n_tri, "marker eof", scan.eof, '1');
        pixels := pixels + 1;
        expected := expected + 1;
        while ok_e and n_e = n_tri loop
          next_data_line(fe, le, ok_e);
          if ok_e then read_edge_row(le, n_e, epx, epy, ee, ecov); end if;
        end loop;
      else
        expected := expected + (to_integer(t.xmax) - to_integer(t.xmin) + 1) *
                               (to_integer(t.ymax) - to_integer(t.ymin) + 1);
        while ok_e and n_e = n_tri loop
          if epx < t.xmin or epx > t.xmax or epy < t.ymin or epy > t.ymax then
            check_bit(n_tri, "margin covered", ecov, '0');
          else
            wait until rising_edge(clk) and out_valid = '1' and out_ready = '1';
            pixels := pixels + 1;
            if scan.px /= epx or scan.py /= epy then
              fail("tri " & integer'image(n_tri) & ": pixel (" &
                   integer'image(to_integer(scan.px)) & "," & integer'image(to_integer(scan.py)) &
                   "), expected (" & integer'image(to_integer(epx)) & "," &
                   integer'image(to_integer(epy)) & ")");
            end if;
            for i in 0 to 2 loop
              if scan.e(i) /= ee(i) then
                fail("tri " & integer'image(n_tri) & " (" & integer'image(to_integer(epx)) & "," &
                     integer'image(to_integer(epy)) & "): E" & integer'image(i) & " = " &
                     to_hstring(std_logic_vector(resize(scan.e(i), 52))) & ", Ada says " &
                     to_hstring(std_logic_vector(resize(ee(i), 52))));
              end if;
            end loop;
            check_bit(n_tri, "kill", scan.kill, not ecov);
            if epx = t.xmax and epy = t.ymax then is_eot := '1'; else is_eot := '0'; end if;
            check_bit(n_tri, "eot", scan.eot, is_eot);
            check_bit(n_tri, "eof", scan.eof, is_eot and t.last);
            if scan.color /= t.color then
              fail("tri " & integer'image(n_tri) & ": color wrong");
            end if;
          end if;
          next_data_line(fe, le, ok_e);
          if ok_e then read_edge_row(le, n_e, epx, epy, ee, ecov); end if;
        end loop;
      end if;

      -- nothing more may come out for this triangle
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      if out_valid /= '0' then
        fail("tri " & integer'image(n_tri) & ": extra pixel after the last one");
      end if;
    end loop;
    file_close(fs);
    file_close(fe);

    if errors = 0 and pixels = expected and pixels > 0 then
      report "raster_scan_tb: " & integer'image(pixels) & " pixels bit-exact with the Ada reference";
      report "raster_scan_tb: ALL TESTS PASSED";
    else
      report "FAIL: errors=" & integer'image(errors) & " pixels=" & integer'image(pixels) &
             " expected=" & integer'image(expected) severity failure;
    end if;
    done <= true;
    wait;
  end process;
end architecture;

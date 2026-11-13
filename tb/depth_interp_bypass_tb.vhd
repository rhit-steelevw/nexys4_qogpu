-- depth_interp_bypass_tb: E3 with INTERP = false (RQ-93)
-- z must equal z_0 whatever z_1, z_2 and E are. Killed pixels are dropped and
-- a killed marker still goes through, same as with INTERP = true.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.qogpu_pkg.all;
use work.raster_pkg.all;

entity depth_interp_bypass_tb is
end entity;

architecture sim of depth_interp_bypass_tb is
  constant CLK_PERIOD : time := 10 ns;

  signal clk   : std_logic := '0';
  signal rst_n : std_logic := '0';
  signal done  : boolean := false;

  signal in_valid, in_ready : std_logic := '0';
  signal in_scan            : scan_t := SCAN_ZERO;
  signal out_valid          : std_logic;
  signal out_ready          : std_logic := '1';
  signal o_px   : fb_x_t;
  signal o_py   : fb_y_t;
  signal o_z    : unsigned(7 downto 0);
  signal o_kill, o_eot, o_eof : std_logic;
  signal o_color : pixel_t;
begin
  clk <= not clk after CLK_PERIOD / 2 when not done;

  dut : entity work.depth_interp
    generic map (DEPTH_W => 8, INTERP => false)
    port map (
      clk_i => clk, rst_n_i => rst_n,
      in_valid_i => in_valid, in_ready_o => in_ready, in_scan_i => in_scan,
      out_valid_o => out_valid, out_ready_i => out_ready,
      out_px_o => o_px, out_py_o => o_py, out_z_o => o_z,
      out_kill_o => o_kill, out_eot_o => o_eot, out_eof_o => o_eof,
      out_color_o => o_color
    );

  watchdog : process
  begin
    wait for 1 ms;
    if not done then
      report "FAIL: depth_interp_bypass_tb timed out" severity failure;
    end if;
    wait;
  end process;

  stim : process
    variable s : scan_t;
    variable errors : natural := 0;

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

    for k in 1 to 5 loop
      s := SCAN_ZERO;
      s.px := to_unsigned(10 * k, FB_X_W);
      s.py := to_unsigned(k, FB_Y_W);
      s.z(0) := to_unsigned(17 * k, DEPTH_MAX_W);
      s.z(1) := to_unsigned(200, DEPTH_MAX_W);
      s.z(2) := to_unsigned(3, DEPTH_MAX_W);
      s.color := std_logic_vector(to_unsigned(k, 8));
      send(s);
      wait until rising_edge(clk) and out_valid = '1' and out_ready = '1';
      if o_z /= to_unsigned(17 * k, 8) or o_kill /= '0' or
         o_px /= to_unsigned(10 * k, FB_X_W) or o_py /= to_unsigned(k, FB_Y_W) or
         o_color /= std_logic_vector(to_unsigned(k, 8)) then
        errors := errors + 1;
        report "fragment " & integer'image(k) & ": wrong output" severity error;
      end if;
    end loop;

    s := SCAN_ZERO;
    s.kill := '1';
    send(s);
    for k in 1 to 5 loop
      wait until rising_edge(clk);
      if out_valid /= '0' then
        errors := errors + 1;
        report "killed pixel was not dropped" severity error;
      end if;
    end loop;

    s := SCAN_ZERO;
    s.kill := '1'; s.eot := '1'; s.eof := '1';
    send(s);
    wait until rising_edge(clk) and out_valid = '1' and out_ready = '1';
    if o_kill /= '1' or o_eot /= '1' or o_eof /= '1' then
      errors := errors + 1;
      report "marker: wrong output" severity error;
    end if;

    if errors = 0 then
      report "depth_interp_bypass_tb: ALL TESTS PASSED";
    else
      report "FAIL: errors=" & integer'image(errors) severity failure;
    end if;
    done <= true;
    wait;
  end process;
end architecture;

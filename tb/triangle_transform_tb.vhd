-- triangle_transform_tb: three-lane Block C wrapper (Integration 3)
--
-- Drives the wrapper directly with B-style triangles (cube faces 1 and 12),
-- identity coefficients (cos = 1.0, sin = 0):
--   1. faces 1 and 12: six screen vertices and depths against an independent
--      reference in this bench (X = (x + 1) * 160, Y = (1 - y) * 120 in 16.16,
--      depth = ((z_raw + 65536) * 255 + 65536) >> 17): expect 201 and 54
--   2. out_ready_i low for 50 clocks after the first result: lanes hold, tri_ready_o
--      stays low, no duplicate and no lost triangle
--   3. two triangles back to back: order kept, out_last_o only on the second
--   4. reset while computing and while stalled at the output: nothing comes out
--      until a new triangle is accepted
-- Pass rule: prints "triangle_transform_tb: ALL TESTS PASSED".
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.qogpu_pkg.all;
use work.qogpu_fx_pkg.all;

entity triangle_transform_tb is
end entity;

architecture sim of triangle_transform_tb is
  constant CLK_PERIOD : time := 10 ns;
  constant ONE        : signed(31 downto 0) := to_signed(65536, 32);
  constant ZERO       : signed(31 downto 0) := (others => '0');
  constant C577       : integer := 37837;   -- cube coordinate, 1/sqrt(3) in 16.16

  -- vertex signs (x, y, z) of each triangle; raw coordinate = sign * C577
  type tri_t is array (0 to 2, 0 to 2) of integer;
  constant F1  : tri_t := ((-1, 1, 1), (1, 1, 1), (-1, -1, 1));      -- vertices 1, 2, 4
  constant F12 : tri_t := ((1, 1, -1), (-1, 1, -1), (1, -1, -1));    -- vertices 23, 24, 22

  type rec_t is record
    x, y  : integer_vector(0 to 2);
    z     : integer_vector(0 to 2);
    last  : std_logic;
    color : pixel_t;
  end record;
  type log_t is array (0 to 15) of rec_t;

  signal clk, rstn : std_logic := '0';
  signal done      : boolean := false;
  signal tri_valid, tri_ready, tri_last : std_logic := '0';
  signal a_id, b_id, c_id : unsigned(31 downto 0) := (others => '0');
  signal ax, ay, az, bx, by, bz, cx, cy, cz : signed(31 downto 0) := (others => '0');
  signal out_valid, out_ready, out_last : std_logic;
  signal v0x, v0y, v1x, v1y, v2x, v2y : q16_t;
  signal z0, z1, z2 : unsigned(7 downto 0);
  signal color : pixel_t;
  signal log_r   : log_t;
  signal log_cnt : natural := 0;

  function exp_x(s : integer) return integer is
  begin
    return (s * C577 + 65536) * 160;
  end function;

  function exp_y(s : integer) return integer is
  begin
    return (65536 - s * C577) * 120;
  end function;

  function exp_z(s : integer) return integer is
  begin
    return ((s * C577 + 65536) * 255 + 65536) / 131072;
  end function;
begin
  clk <= not clk after CLK_PERIOD / 2 when not done;

  dut : entity work.triangle_transform
    port map (
      clk_i => clk, rstn_i => rstn,
      tri_valid_i => tri_valid, tri_ready_o => tri_ready, tri_last_i => tri_last,
      vertex_a_id_i => a_id, vertex_b_id_i => b_id, vertex_c_id_i => c_id,
      vertex_a_x_i => ax, vertex_a_y_i => ay, vertex_a_z_i => az,
      vertex_b_x_i => bx, vertex_b_y_i => by, vertex_b_z_i => bz,
      vertex_c_x_i => cx, vertex_c_y_i => cy, vertex_c_z_i => cz,
      cos_x_i => ONE, sin_x_i => ZERO, cos_y_i => ONE,
      sin_y_i => ZERO, cos_z_i => ONE, sin_z_i => ZERO,
      out_valid_o => out_valid, out_ready_i => out_ready,
      out_v0_x_o => v0x, out_v0_y_o => v0y, out_v1_x_o => v1x, out_v1_y_o => v1y,
      out_v2_x_o => v2x, out_v2_y_o => v2y,
      out_v0_z_o => z0, out_v1_z_o => z1, out_v2_z_o => z2,
      out_color_o => color, out_last_o => out_last
    );

  -- logs every accepted output triangle
  monitor : process (clk)
    variable r : rec_t;
  begin
    if rising_edge(clk) then
      if rstn = '1' and out_valid = '1' and out_ready = '1' then
        r.x := (to_integer(v0x), to_integer(v1x), to_integer(v2x));
        r.y := (to_integer(v0y), to_integer(v1y), to_integer(v2y));
        r.z := (to_integer(z0), to_integer(z1), to_integer(z2));
        r.last := out_last;
        r.color := color;
        log_r(log_cnt mod 16) <= r;
        log_cnt <= log_cnt + 1;
      end if;
    end if;
  end process;

  stim : process
    variable errors : natural := 0;
    variable base   : natural;

    procedure tick is
    begin
      wait until rising_edge(clk);
    end procedure;

    procedure drive(t : tri_t; last : std_logic) is
    begin
      ax <= to_signed(t(0, 0) * C577, 32); ay <= to_signed(t(0, 1) * C577, 32); az <= to_signed(t(0, 2) * C577, 32);
      bx <= to_signed(t(1, 0) * C577, 32); by <= to_signed(t(1, 1) * C577, 32); bz <= to_signed(t(1, 2) * C577, 32);
      cx <= to_signed(t(2, 0) * C577, 32); cy <= to_signed(t(2, 1) * C577, 32); cz <= to_signed(t(2, 2) * C577, 32);
      tri_last <= last;
      tri_valid <= '1';
    end procedure;

    -- present a triangle and wait until it is accepted
    procedure send(t : tri_t; last : std_logic) is
    begin
      drive(t, last);
      loop
        tick;
        exit when tri_ready = '1';
      end loop;
      tri_valid <= '0';
    end procedure;

    procedure check(cond : boolean; msg : string) is
    begin
      if not cond then
        report "FAIL: " & msg severity error;
        errors := errors + 1;
      end if;
    end procedure;

    procedure check_rec(idx : natural; t : tri_t; last : std_logic; msg : string) is
      variable r : rec_t;
    begin
      r := log_r(idx mod 16);
      for i in 0 to 2 loop
        check(r.x(i) = exp_x(t(i, 0)), msg & ": X" & integer'image(i));
        check(r.y(i) = exp_y(t(i, 1)), msg & ": Y" & integer'image(i));
        check(r.z(i) = exp_z(t(i, 2)), msg & ": Z" & integer'image(i));
      end loop;
      check(r.last = last, msg & ": last");
      check(r.color = x"E0", msg & ": color");
    end procedure;

    procedure wait_out(n : natural) is
    begin
      for i in 1 to 100 loop
        exit when log_cnt >= n;
        tick;
      end loop;
      check(log_cnt >= n, "timed out waiting for output");
    end procedure;
  begin
    out_ready <= '1';
    rstn <= '0';
    wait for 5 * CLK_PERIOD;
    tick;
    rstn <= '1';
    tick;

    -- case 1: faces 1 and 12, reference values and depths
    check(exp_z(1) = 201 and exp_z(-1) = 54, "reference depths");
    base := log_cnt;
    send(F1, '0');
    wait_out(base + 1);
    send(F12, '1');
    wait_out(base + 2);
    tick; tick;
    check(log_cnt = base + 2, "case 1: output count");
    check_rec(base, F1, '0', "case 1 face 1");
    check_rec(base + 1, F12, '1', "case 1 face 12");

    -- case 2: output stalled, lanes hold
    out_ready <= '0';
    base := log_cnt;
    send(F1, '0');
    drive(F12, '1');
    for i in 1 to 30 loop
      exit when out_valid = '1';
      tick;
    end loop;
    check(out_valid = '1', "case 2: no output to hold");
    for i in 1 to 50 loop
      tick;
      check(tri_ready = '0', "case 2: tri_ready rose during stall");
      check(out_valid = '1', "case 2: out_valid dropped during stall");
    end loop;
    check(log_cnt = base, "case 2: output taken during stall");
    out_ready <= '1';
    loop
      tick;
      exit when tri_ready = '1';
    end loop;
    tri_valid <= '0';
    wait_out(base + 2);
    for i in 1 to 20 loop tick; end loop;
    check(log_cnt = base + 2, "case 2: duplicate or lost triangle");
    check_rec(base, F1, '0', "case 2 face 1");
    check_rec(base + 1, F12, '1', "case 2 face 12");

    -- case 3: back to back, order and last marker
    base := log_cnt;
    send(F1, '0');
    send(F12, '1');
    wait_out(base + 2);
    for i in 1 to 20 loop tick; end loop;
    check(log_cnt = base + 2, "case 3: output count");
    check_rec(base, F1, '0', "case 3 first");
    check_rec(base + 1, F12, '1', "case 3 second");

    -- case 4a: reset while the lanes are computing
    base := log_cnt;
    send(F1, '0');
    rstn <= '0';
    tick; tick;
    rstn <= '1';
    for i in 1 to 30 loop
      tick;
      check(out_valid = '0', "case 4a: output after reset");
    end loop;
    check(log_cnt = base, "case 4a: logged output after reset");
    send(F12, '1');
    wait_out(base + 1);
    for i in 1 to 20 loop tick; end loop;
    check(log_cnt = base + 1, "case 4a: output count after restart");
    check_rec(base, F12, '1', "case 4a restart");

    -- case 4b: reset while stalled at the output
    out_ready <= '0';
    base := log_cnt;
    send(F1, '0');
    for i in 1 to 30 loop
      exit when out_valid = '1';
      tick;
    end loop;
    check(out_valid = '1', "case 4b: expected a held output");
    rstn <= '0';
    tick; tick;
    rstn <= '1';
    out_ready <= '1';
    for i in 1 to 30 loop
      tick;
      check(out_valid = '0', "case 4b: output after reset");
    end loop;
    check(log_cnt = base, "case 4b: logged output after reset");
    send(F1, '1');
    wait_out(base + 1);
    check_rec(base, F1, '1', "case 4b restart");

    if errors = 0 then
      report "triangle_transform_tb: ALL TESTS PASSED";
    else
      report "FAIL: errors=" & integer'image(errors) severity failure;
    end if;
    done <= true;
    wait;
  end process;
end architecture;

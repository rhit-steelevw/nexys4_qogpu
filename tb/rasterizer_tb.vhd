-- rasterizer_tb: tri_setup -> rasterizer, chained (RQ-93)
--
-- Block C is not in this bench: screen-space vertices go straight into tri_setup.
--
-- Frame 1: setup.csv rows 4 and 5 (they share an edge). Every pixel must be hit
--   at most once, and each triangle's covered-pixel count must equal the number
--   of its rows in interp.csv (run make vectors first).
-- Frame 2: the MVP scene, green (z = 64) in front of blue (z = 191), both
--   overlapping. A small model of E4/E6 in this bench keeps a depth buffer and
--   writes the color of passing fragments into a framebuffer.
-- Each frame is dumped with frame_dump_pkg to shared_edge.hex and two_triangles.hex
--   (one RGB332 byte per line, see docs/memos/frame_dump.md).
-- rasterizer out_ready is low 3 of every 7 clocks. Markers (kill = 1) are never drawn.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.qogpu_pkg.all;
use work.qogpu_fx_pkg.all;
use work.raster_pkg.all;
use work.raster_tb_pkg.all;
use work.frame_dump_pkg.all;

entity rasterizer_tb is
end entity;

architecture sim of rasterizer_tb is
  constant CLK_PERIOD : time := 10 ns;
  constant GREEN      : pixel_t := x"1C";
  constant BLUE       : pixel_t := x"03";

  type nat256_t is array (0 to 255) of natural;

  signal clk   : std_logic := '0';
  signal rst_n : std_logic := '0';
  signal done  : boolean := false;
  signal cyc   : natural := 0;
  signal phase : natural := 1;

  signal in_valid, in_ready, in_last : std_logic := '0';
  signal vx0, vy0, vx1, vy1, vx2, vy2 : q16_t := (others => '0');
  signal z0, z1, z2 : unsigned(7 downto 0) := (others => '0');
  signal color : pixel_t := (others => '0');

  signal t_valid, t_ready : std_logic;
  signal tri : tri_t;

  signal out_valid, out_ready : std_logic := '0';
  signal o_px   : fb_x_t;
  signal o_py   : fb_y_t;
  signal o_z    : unsigned(7 downto 0);
  signal o_kill, o_eot, o_eof : std_logic;
  signal o_color : pixel_t;

  signal wr_en   : std_logic := '0';
  signal wr_addr : fb_addr_t := (others => '0');
  signal wr_data : pixel_t := (others => '0');
  signal wr_en1, wr_en2 : std_logic;
  signal rd_addr1, rd_addr2 : fb_addr_t := (others => '0');
  signal rd_data1, rd_data2 : pixel_t;

  -- per-frame results, set by the consumer on eof
  signal frames    : natural := 0;
  signal res_hits  : natural := 0;    -- most hits on any one pixel
  signal res_eot   : natural := 0;
  signal res_cnt   : nat256_t := (others => 0);   -- drawn fragments per color
begin
  clk <= not clk after CLK_PERIOD / 2 when not done;

  process (clk)
  begin
    if rising_edge(clk) then
      cyc <= cyc + 1;
    end if;
  end process;
  out_ready <= '0' when (cyc mod 7) < 3 else '1';

  setup : entity work.tri_setup
    port map (
      clk_i => clk, rst_n_i => rst_n,
      in_valid_i => in_valid, in_ready_o => in_ready,
      in_v0_x_i => vx0, in_v0_y_i => vy0,
      in_v1_x_i => vx1, in_v1_y_i => vy1,
      in_v2_x_i => vx2, in_v2_y_i => vy2,
      in_v0_z_i => z0, in_v1_z_i => z1, in_v2_z_i => z2,
      in_color_i => color, in_last_i => in_last,
      out_valid_o => t_valid, out_ready_i => t_ready, out_tri_o => tri
    );

  dut : entity work.rasterizer
    generic map (DEPTH_W => 8, INTERP => true)
    port map (
      clk_i => clk, rst_n_i => rst_n,
      in_valid_i => t_valid, in_ready_o => t_ready, in_tri_i => tri,
      out_valid_o => out_valid, out_ready_i => out_ready,
      out_px_o => o_px, out_py_o => o_py, out_z_o => o_z,
      out_kill_o => o_kill, out_eot_o => o_eot, out_eof_o => o_eof,
      out_color_o => o_color
    );

  wr_en1 <= wr_en when phase = 1 else '0';
  wr_en2 <= wr_en when phase = 2 else '0';

  fb1 : entity work.framebuffer
    port map (clk_i => clk, wr_en_i => wr_en1, wr_addr_i => wr_addr, wr_data_i => wr_data,
              rd_addr_i => rd_addr1, rd_data_o => rd_data1);
  fb2 : entity work.framebuffer
    port map (clk_i => clk, wr_en_i => wr_en2, wr_addr_i => wr_addr, wr_data_i => wr_data,
              rd_addr_i => rd_addr2, rd_data_o => rd_data2);

  -- stands in for E4 + E6
  consumer : process (clk)
    type hit_arr_t is array (0 to FB_PIXELS - 1) of natural;
    type z_arr_t   is array (0 to FB_PIXELS - 1) of natural;
    variable hits  : hit_arr_t := (others => 0);
    variable zbuf  : z_arr_t := (others => 255);
    variable cnt   : nat256_t := (others => 0);
    variable n_eot : natural := 0;
    variable max_h : natural;
    variable a     : natural;
  begin
    if rising_edge(clk) then
      wr_en <= '0';
      if out_valid = '1' and out_ready = '1' then
        if o_kill = '0' then
          a := to_integer(o_py) * FB_W + to_integer(o_px);
          hits(a) := hits(a) + 1;
          cnt(to_integer(unsigned(o_color))) := cnt(to_integer(unsigned(o_color))) + 1;
          if to_integer(o_z) < zbuf(a) then
            zbuf(a) := to_integer(o_z);
            wr_en   <= '1';
            wr_addr <= to_unsigned(a, FB_ADDR_W);
            wr_data <= o_color;
          end if;
        end if;
        if o_eot = '1' then
          n_eot := n_eot + 1;
        end if;
        if o_eof = '1' then
          max_h := 0;
          for i in 0 to FB_PIXELS - 1 loop
            if hits(i) > max_h then max_h := hits(i); end if;
          end loop;
          res_hits <= max_h;
          res_eot  <= n_eot;
          res_cnt  <= cnt;
          frames   <= frames + 1;
          hits  := (others => 0);
          zbuf  := (others => 255);
          cnt   := (others => 0);
          n_eot := 0;
        end if;
      end if;
    end if;
  end process;

  watchdog : process
  begin
    wait for 100 ms;
    if not done then
      report "FAIL: rasterizer_tb timed out" severity failure;
    end if;
    wait;
  end process;

  stim : process
    file fs, fi : text;
    variable ls, li : line;
    variable ok : boolean;
    variable n  : integer;
    variable t  : tri_t;
    variable ipx : fb_x_t;
    variable ipy : fb_y_t;
    variable iz  : unsigned(7 downto 0);
    variable expect_cnt : nat256_t := (others => 0);
    variable errors : natural := 0;
    variable lastv : std_logic;

    procedure fail(msg : string) is
    begin
      errors := errors + 1;
      report msg severity error;
    end procedure;

    function q(n : integer) return q16_t is
    begin
      return to_signed(n * 65536, 32);
    end function;

    procedure send(a0x, a0y, a1x, a1y, a2x, a2y : q16_t; za, zb, zc : unsigned(7 downto 0);
                   c : pixel_t; last : std_logic) is
    begin
      vx0 <= a0x; vy0 <= a0y; vx1 <= a1x; vy1 <= a1y; vx2 <= a2x; vy2 <= a2y;
      z0 <= za; z1 <= zb; z2 <= zc; color <= c; in_last <= last;
      in_valid <= '1';
      wait until rising_edge(clk) and in_ready = '1';
      in_valid <= '0';
    end procedure;

    procedure peek(signal a : out fb_addr_t; signal d : in pixel_t; x, y : natural;
                   variable r : out pixel_t) is
    begin
      a <= to_unsigned(y * FB_W + x, FB_ADDR_W);
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      wait for 1 ns;
      r := d;
    end procedure;

    procedure expect_pixel(signal a : out fb_addr_t; signal d : in pixel_t; x, y : natural;
                           exp : pixel_t; name : string) is
      variable r : pixel_t;
    begin
      peek(a, d, x, y, r);
      if r /= exp then
        fail(name & " pixel (" & integer'image(x) & "," & integer'image(y) & ") = " &
             to_hstring(r) & ", expected " & to_hstring(exp));
      end if;
    end procedure;
  begin
    rst_n <= '0';
    wait for 5 * CLK_PERIOD;
    wait until rising_edge(clk);
    rst_n <= '1';

    -- covered-pixel counts from the Ada reference
    file_open(fi, "interp.csv", read_mode);
    next_data_line(fi, li, ok);
    while ok loop
      read_interp_row(li, n, ipx, ipy, iz);
      expect_cnt(n) := expect_cnt(n) + 1;
      next_data_line(fi, li, ok);
    end loop;
    file_close(fi);

    -- frame 1: shared edge, setup.csv rows 4 and 5
    file_open(fs, "setup.csv", read_mode);
    for k in 1 to 5 loop
      next_data_line(fs, ls, ok);
      read_setup_row(ls, n, t);
      if k >= 4 then
        if k = 5 then lastv := '1'; else lastv := '0'; end if;
        send(t.vx(0), t.vy(0), t.vx(1), t.vy(1), t.vx(2), t.vy(2),
             t.z(0)(7 downto 0), t.z(1)(7 downto 0), t.z(2)(7 downto 0),
             t.color, lastv);
      end if;
    end loop;
    file_close(fs);

    wait until rising_edge(clk) and frames = 1;
    if res_hits /= 1 then
      fail("frame 1: a pixel was hit " & integer'image(res_hits) & " times, expected exactly 1");
    end if;
    for c in 4 to 5 loop
      if expect_cnt(c) = 0 or res_cnt(c) /= expect_cnt(c) then
        fail("frame 1: tri " & integer'image(c) & " drew " & integer'image(res_cnt(c)) &
             " pixels, interp.csv has " & integer'image(expect_cnt(c)));
      end if;
    end loop;
    if res_eot /= 2 then
      fail("frame 1: " & integer'image(res_eot) & " end-of-triangle markers, expected 2");
    end if;
    for k in 1 to 20 loop
      wait until rising_edge(clk);
      if out_valid = '1' then fail("frame 1: output after eof"); exit; end if;
    end loop;
    dump_frame("shared_edge.hex", clk, rd_addr1, rd_data1);

    -- frame 2: MVP scene in screen space (Viewport_X = (x+1)*160, Viewport_Y = (1-y)*120)
    phase <= 2;
    send(q(40), q(60), q(200), q(60), q(120), q(210),
         to_unsigned(64, 8), to_unsigned(64, 8), to_unsigned(64, 8), GREEN, '0');
    send(q(120), q(30), q(280), q(30), q(200), q(180),
         to_unsigned(191, 8), to_unsigned(191, 8), to_unsigned(191, 8), BLUE, '1');

    wait until rising_edge(clk) and frames = 2;
    if res_eot /= 2 then
      fail("frame 2: " & integer'image(res_eot) & " end-of-triangle markers, expected 2");
    end if;
    if res_cnt(to_integer(unsigned(GREEN))) = 0 or res_cnt(to_integer(unsigned(BLUE))) = 0 then
      fail("frame 2: a triangle drew no pixels");
    end if;
    for k in 1 to 20 loop
      wait until rising_edge(clk);
      if out_valid = '1' then fail("frame 2: output after eof"); exit; end if;
    end loop;
    expect_pixel(rd_addr2, rd_data2, 160, 100, GREEN, "overlap");
    expect_pixel(rd_addr2, rd_data2, 100, 100, GREEN, "green only");
    expect_pixel(rd_addr2, rd_data2, 230, 60, BLUE, "blue only");
    expect_pixel(rd_addr2, rd_data2, 5, 5, x"00", "background");
    dump_frame("two_triangles.hex", clk, rd_addr2, rd_data2);

    if errors = 0 then
      report "rasterizer_tb: shared edge covered once, MVP scene correct";
      report "rasterizer_tb: ALL TESTS PASSED";
    else
      report "FAIL: errors=" & integer'image(errors) severity failure;
    end if;
    done <= true;
    wait;
  end process;
end architecture;

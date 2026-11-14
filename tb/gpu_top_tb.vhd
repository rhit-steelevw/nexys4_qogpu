-- gpu_top_tb: Integration 2 end to end, checked at the VGA pins.
-- Starts one frame, waits for frame_done_o, then samples vga_r/g/b over one
-- full active frame (every second pixel of every second line undoes the 2x
-- doubling) and writes the 320x240 image to gpu_top.hex, same format as
-- draw_pipeline.hex and two_triangles.hex.
-- Pixel (x, y) leaves the registered outputs 4 * ((V_TOTAL - V_SYNC_START + y)
-- * H_TOTAL + x) clocks after vga_vs_n falls.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use work.qogpu_pkg.all;

entity gpu_top_tb is
end entity;

architecture sim of gpu_top_tb is
  constant CLK_PERIOD : time := 10 ns;
  constant PIX_DIV    : natural := 4;
  constant H_TOTAL    : natural := 800;
  constant LINES_TO_FRAME : natural := 525 - 490;
  constant GREEN : pixel_t := x"1C";
  constant BLUE  : pixel_t := x"03";
  constant BLACK : pixel_t := x"00";

  type image_t is array (0 to FB_PIXELS - 1) of pixel_t;

  signal clk, rst_n, start : std_logic := '0';
  signal vga_r, vga_g : std_logic_vector(2 downto 0);
  signal vga_b : std_logic_vector(1 downto 0);
  signal vga_hs_n, vga_vs_n : std_logic;
  signal busy, frame_done, err : std_logic;
  signal done : boolean := false;
begin
  clk <= not clk after CLK_PERIOD / 2 when not done;

  dut : entity work.gpu_top
    port map (
      clk => clk, rst_n => rst_n, start_i => start,
      vga_r => vga_r, vga_g => vga_g, vga_b => vga_b,
      vga_hs_n => vga_hs_n, vga_vs_n => vga_vs_n,
      busy_o => busy, frame_done_o => frame_done, error_o => err
    );

  stim : process
    variable errors : natural := 0;
    variable img    : image_t;
    variable n, prev_n : natural;
    variable row    : line;
    file output     : text open write_mode is "gpu_top.hex";

    procedure expect_pixel(x, y : natural; exp : pixel_t; name : string) is
    begin
      if img(y * FB_W + x) /= exp then
        report name & " pixel (" & integer'image(x) & "," & integer'image(y) & ") = " &
               to_hstring(img(y * FB_W + x)) & ", expected " & to_hstring(exp) severity error;
        errors := errors + 1;
      end if;
    end procedure;
  begin
    rst_n <= '0';
    wait for 10 * CLK_PERIOD;
    wait until rising_edge(clk);
    rst_n <= '1';
    for i in 1 to 20 loop wait until rising_edge(clk); end loop;

    assert frame_done = '0' report "frame_done_o high before start" severity failure;
    assert busy = '0' report "busy_o high before start" severity failure;

    start <= '1';
    wait until rising_edge(clk);
    start <= '0';
    wait until rising_edge(clk);
    wait for 1 ns;
    assert busy = '1' report "busy_o did not rise after start" severity failure;

    wait until frame_done = '1' for 20 ms;
    if frame_done /= '1' then
      report "FAIL: frame_done_o never rose" severity failure;
    end if;
    assert err = '0' report "error_o set" severity failure;

    if vga_vs_n = '0' then
      wait until vga_vs_n = '1';
    end if;
    wait until vga_vs_n = '0';
    wait for 1 ns;

    prev_n := 0;
    for y in 0 to FB_H - 1 loop
      for x in 0 to FB_W - 1 loop
        n := PIX_DIV * ((LINES_TO_FRAME + 2 * y) * H_TOTAL + 2 * x);
        wait for (n - prev_n) * CLK_PERIOD;
        prev_n := n;
        img(y * FB_W + x) := vga_r & vga_g & vga_b;
      end loop;
    end loop;

    expect_pixel(160, 100, GREEN, "overlap");
    expect_pixel(100, 100, GREEN, "green only");
    expect_pixel(230, 60, BLUE, "blue only");
    expect_pixel(5, 5, BLACK, "background");

    for i in 0 to FB_PIXELS - 1 loop
      hwrite(row, img(i));
      writeline(output, row);
    end loop;
    file_close(output);

    if errors = 0 then
      report "gpu_top_tb: ALL TESTS PASSED";
    else
      report "FAIL: errors=" & integer'image(errors) severity failure;
    end if;
    done <= true;
    wait;
  end process;
end architecture;

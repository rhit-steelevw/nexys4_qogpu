-- draw_pipeline_tb.vhd : Integration 2 regression (RQ-99), SKELETON
--
-- scene_stub -> draw_pipeline, with the real clear_engine, mem_mux,
-- mem_ctrl_bram and framebuffer (same pieces as gpu_top, minus VGA and Block A).
--   1. reset; wait for mem_ready
--   2. clear: color x"00", depth 2^DEPTH_W - 1 (BRAM powers up at 0: without the
--      clear every fragment fails the depth test)
--   3. start the stub; wait for frame_done (timeout = failure)
--   4. pixel checks from rasterizer_tb frame 2; no fb/memory write after frame_done
--   5. dump_frame -> DUMP_FILE; must equal rasterizer_tb's two_triangles.hex
-- BLUE_FIRST = true is run through draw_pipeline_blue_first_tb (wrapper entity:
-- generics are not passed on the command line, see scripts/sim.tcl).
-- Pass rule: prints "draw_pipeline_tb: ALL TESTS PASSED".
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.qogpu_pkg.all;
use work.qogpu_fx_pkg.all;
use work.mem_if_pkg.all;
use work.frame_dump_pkg.all;

entity draw_pipeline_tb is
  generic (
    BLUE_FIRST : boolean := false;
    DUMP_FILE  : string  := "draw_pipeline.hex";
    TB_NAME    : string  := "draw_pipeline_tb"
  );
end entity;

architecture sim of draw_pipeline_tb is
  constant DEPTH_W    : positive := 8;
  constant CLK_PERIOD : time := 10 ns;
  constant GREEN      : pixel_t := x"1C";
  constant BLUE       : pixel_t := x"03";
  constant BLACK      : pixel_t := x"00";
  constant TIMEOUT    : time := 20 ms;

  signal clk   : std_logic := '0';
  signal rst_n : std_logic := '0';
  signal done  : boolean := false;

  -- stub <-> pipeline
  signal start_valid, start_ready : std_logic := '0';
  signal s_valid, s_ready : std_logic;
  signal s_v0x, s_v0y, s_v1x, s_v1y, s_v2x, s_v2y : q16_t;
  signal s_z0, s_z1, s_z2 : unsigned(DEPTH_W - 1 downto 0);
  signal s_color : pixel_t;
  signal s_last  : std_logic;

  -- pipeline outputs
  signal dp_fb_we : std_logic;
  signal dp_fb_addr : fb_addr_t;
  signal dp_fb_data : pixel_t;
  signal frame_done : std_logic;

  -- clear engine
  signal ce_start, ce_done, ce_fb_we, ce_req_v, ce_req_we : std_logic := '0';
  signal ce_fb_addr, ce_req_addr : fb_addr_t;
  signal ce_fb_data : pixel_t;
  signal ce_req_wdata : std_logic_vector(DEPTH_W - 1 downto 0);

  -- memory
  signal reqs   : mem_req_array_t(0 to MEM_CLIENTS - 1);
  signal readys : std_logic_vector(0 to MEM_CLIENTS - 1);
  signal mem_req : mem_req_t;
  signal mem_req_ready, mem_ready : std_logic;
  signal mem_rsp : mem_rsp_t;

  -- framebuffer
  signal fb_we : std_logic;
  signal fb_waddr, rd_addr : fb_addr_t := (others => '0');
  signal fb_wdata, rd_data : pixel_t;

  signal frame_count : natural := 0;
  signal mon_errors  : natural := 0;
  signal after_done  : boolean := false;
begin
  clk <= not clk after CLK_PERIOD / 2 when not done;

  u_stub : entity work.scene_stub
    generic map (DEPTH_W => DEPTH_W, BLUE_FIRST => BLUE_FIRST)
    port map (
      clk_i => clk, rst_n_i => rst_n,
      start_valid_i => start_valid, start_ready_o => start_ready,
      out_valid_o => s_valid, out_ready_i => s_ready,
      out_v0_x_o => s_v0x, out_v0_y_o => s_v0y, out_v1_x_o => s_v1x, out_v1_y_o => s_v1y,
      out_v2_x_o => s_v2x, out_v2_y_o => s_v2y,
      out_v0_z_o => s_z0, out_v1_z_o => s_z1, out_v2_z_o => s_z2,
      out_color_o => s_color, out_last_o => s_last
    );

  dut : entity work.draw_pipeline
    generic map (DEPTH_W => DEPTH_W, INTERP => true)
    port map (
      clk_i => clk, rst_n_i => rst_n,
      in_valid_i => s_valid, in_ready_o => s_ready,
      in_v0_x_i => s_v0x, in_v0_y_i => s_v0y, in_v1_x_i => s_v1x, in_v1_y_i => s_v1y,
      in_v2_x_i => s_v2x, in_v2_y_i => s_v2y,
      in_v0_z_i => s_z0, in_v1_z_i => s_z1, in_v2_z_i => s_z2,
      in_color_i => s_color, in_last_i => s_last,
      fb_we_o => dp_fb_we, fb_waddr_o => dp_fb_addr, fb_wdata_o => dp_fb_data,
      e4_req_o => reqs(MEM_CLIENT_E4), e4_req_ready_i => readys(MEM_CLIENT_E4),
      mem_rsp_i => mem_rsp,
      e6_req_o => reqs(MEM_CLIENT_E6), e6_req_ready_i => readys(MEM_CLIENT_E6),
      tri_done_o => open, frame_done_o => frame_done
    );

  u_clear : entity work.clear_engine
    generic map (DEPTH_W => DEPTH_W)
    port map (
      clk_i => clk, rst_n_i => rst_n,
      start_i => ce_start, color_i => BLACK, depth_i => depth_clear(DEPTH_W),
      busy_o => open, done_o => ce_done,
      fb_we_o => ce_fb_we, fb_waddr_o => ce_fb_addr, fb_wdata_o => ce_fb_data,
      mem_ready_i => mem_ready,
      mem_req_valid_o => ce_req_v, mem_req_ready_i => readys(MEM_CLIENT_CLEAR),
      mem_req_we_o => ce_req_we, mem_req_addr_o => ce_req_addr, mem_req_wdata_o => ce_req_wdata
    );
  reqs(MEM_CLIENT_CLEAR) <= (valid => ce_req_v, we => ce_req_we, addr => ce_req_addr,
                             wdata => to_mem_data(ce_req_wdata));

  u_mux : entity work.mem_mux
    port map (reqs_i => reqs, readys_o => readys, req_o => mem_req, req_ready_i => mem_req_ready);

  u_mem : entity work.mem_ctrl_bram
    generic map (DEPTH_W => DEPTH_W)
    port map (clk_i => clk, rst_n_i => rst_n,
              req => mem_req, req_ready => mem_req_ready, rsp => mem_rsp, mem_ready => mem_ready);

  fb_we    <= ce_fb_we or dp_fb_we;
  fb_waddr <= ce_fb_addr when ce_fb_we = '1' else dp_fb_addr;
  fb_wdata <= ce_fb_data when ce_fb_we = '1' else dp_fb_data;

  u_fb : entity work.framebuffer
    port map (clk_i => clk, wr_en_i => fb_we, wr_addr_i => fb_waddr, wr_data_i => fb_wdata,
              rd_addr_i => rd_addr, rd_data_o => rd_data);

  monitor : process (clk)
  begin
    if rising_edge(clk) then
      if frame_done = '1' then
        frame_count <= frame_count + 1;
        if frame_count >= 1 then
          report "monitor: frame_done pulsed more than once" severity error;
          mon_errors <= mon_errors + 1;
        end if;
        after_done <= true;
      end if;
      if after_done and (fb_we = '1' or mem_req.valid = '1') then
        report "monitor: write or memory request after frame_done" severity error;
        mon_errors <= mon_errors + 1;
      end if;
      if ce_fb_we = '1' and dp_fb_we = '1' then
        report "monitor: clear engine and pipeline both write the framebuffer" severity error;
        mon_errors <= mon_errors + 1;
      end if;
    end if;
  end process;

  stim : process
    variable errors : natural := 0;

    procedure expect_pixel(x, y : natural; exp : pixel_t; name : string) is
    begin
      rd_addr <= to_unsigned(y * FB_W + x, FB_ADDR_W);
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      wait for 1 ns;
      if rd_data /= exp then
        report name & " pixel (" & integer'image(x) & "," & integer'image(y) & ") = " &
               to_hstring(rd_data) & ", expected " & to_hstring(exp) severity error;
        errors := errors + 1;
      end if;
    end procedure;
  begin
    rst_n <= '0';
    wait for 5 * CLK_PERIOD;
    wait until rising_edge(clk);
    rst_n <= '1';

    wait until mem_ready = '1' for TIMEOUT;
    if mem_ready /= '1' then
      report "FAIL: mem_ready never rose" severity failure;
    end if;

    wait until rising_edge(clk);
    ce_start <= '1';
    wait until rising_edge(clk);
    ce_start <= '0';
    wait until ce_done = '1' for TIMEOUT;
    if ce_done /= '1' then
      report "FAIL: clear never finished" severity failure;
    end if;
    wait until rising_edge(clk);

    start_valid <= '1';
    wait until rising_edge(clk) and start_ready = '1';
    start_valid <= '0';

    wait until frame_done = '1' for TIMEOUT;
    if frame_done /= '1' then
      report "FAIL: frame_done never came" severity failure;
    end if;

    for i in 1 to 50 loop
      wait until rising_edge(clk);
    end loop;

    expect_pixel(160, 100, GREEN, "overlap");
    expect_pixel(100, 100, GREEN, "green only");
    expect_pixel(230, 60, BLUE, "blue only");
    expect_pixel(5, 5, BLACK, "background");

    dump_frame(DUMP_FILE, clk, rd_addr, rd_data);

    errors := errors + mon_errors;
    if frame_count /= 1 then
      report "frame_done count = " & integer'image(frame_count) & ", expected 1" severity error;
      errors := errors + 1;
    end if;

    if errors = 0 then
      report TB_NAME & ": ALL TESTS PASSED";
    else
      report "FAIL: errors=" & integer'image(errors) severity failure;
    end if;
    done <= true;
    wait;
  end process;
end architecture;

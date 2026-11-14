-- Runs the actual memtest controller against the fast MIG UI model.
-- The second instance deliberately flips one returned data bit and must fail.
library ieee;
use ieee.std_logic_1164.all;

entity ddr2_memtest_tb is end entity;

architecture test of ddr2_memtest_tb is
  constant ADDR_W : positive := 27;
  constant DATA_W : positive := 64;
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal calib_ok, calib_bad : std_logic;
  signal addr_ok, addr_bad : std_logic_vector(ADDR_W-1 downto 0);
  signal cmd_ok, cmd_bad : std_logic_vector(2 downto 0);
  signal en_ok, en_bad, rdy_ok, rdy_bad : std_logic;
  signal wd_ok, wd_bad : std_logic_vector(DATA_W-1 downto 0);
  signal wm_ok, wm_bad : std_logic_vector(DATA_W/8-1 downto 0);
  signal wr_ok, wr_bad, we_ok, we_bad, wready_ok, wready_bad : std_logic;
  signal rd_ok, rd_bad, rd_bad_corrupt : std_logic_vector(DATA_W-1 downto 0);
  signal rv_ok, rv_bad, re_ok, re_bad : std_logic;
  signal led_ok, led_bad : std_logic_vector(2 downto 0);
  signal seg_ok, seg_bad : std_logic_vector(6 downto 0);
  signal an_ok, an_bad : std_logic_vector(3 downto 0);
  signal dp_ok, dp_bad : std_logic;
begin
  clk <= not clk after 5 ns;

  good_model : entity work.mig_ui_model
    generic map (ADDR_W => ADDR_W, DATA_W => DATA_W, MEM_WORDS => 128,
                 RD_LAT_MIN => 3, RD_LAT_MAX => 8, STALL_PCT => 10, SEED => 11)
    port map (ui_clk => clk, ui_rst => rst, init_calib_complete => calib_ok,
      app_addr => addr_ok, app_cmd => cmd_ok, app_en => en_ok, app_rdy => rdy_ok,
      app_wdf_data => wd_ok, app_wdf_mask => wm_ok, app_wdf_wren => wr_ok,
      app_wdf_end => we_ok, app_wdf_rdy => wready_ok,
      app_rd_data => rd_ok, app_rd_data_valid => rv_ok, app_rd_data_end => re_ok);

  bad_model : entity work.mig_ui_model
    generic map (ADDR_W => ADDR_W, DATA_W => DATA_W, MEM_WORDS => 128,
                 RD_LAT_MIN => 3, RD_LAT_MAX => 8, STALL_PCT => 10, SEED => 17)
    port map (ui_clk => clk, ui_rst => rst, init_calib_complete => calib_bad,
      app_addr => addr_bad, app_cmd => cmd_bad, app_en => en_bad, app_rdy => rdy_bad,
      app_wdf_data => wd_bad, app_wdf_mask => wm_bad, app_wdf_wren => wr_bad,
      app_wdf_end => we_bad, app_wdf_rdy => wready_bad,
      app_rd_data => rd_bad, app_rd_data_valid => rv_bad, app_rd_data_end => re_bad);

  good_test : entity work.ddr2_memtest
    generic map (ADDR_W => ADDR_W, DATA_W => DATA_W, TEST_BYTES => 256)
    port map (ui_clk => clk, ui_rst => rst, init_calib_complete => calib_ok,
      app_addr => addr_ok, app_cmd => cmd_ok, app_en => en_ok, app_rdy => rdy_ok,
      app_wdf_data => wd_ok, app_wdf_mask => wm_ok, app_wdf_wren => wr_ok,
      app_wdf_end => we_ok, app_wdf_rdy => wready_ok,
      app_rd_data => rd_ok, app_rd_data_valid => rv_ok, app_rd_data_end => re_ok,
      led => led_ok, seg => seg_ok, an => an_ok, dp => dp_ok);

  -- Fault is introduced only on the return path, not in the memory contents.
  rd_bad_corrupt <= rd_bad xor (0 => '1', others => '0');

  bad_test : entity work.ddr2_memtest
    generic map (ADDR_W => ADDR_W, DATA_W => DATA_W, TEST_BYTES => 256)
    port map (ui_clk => clk, ui_rst => rst, init_calib_complete => calib_bad,
      app_addr => addr_bad, app_cmd => cmd_bad, app_en => en_bad, app_rdy => rdy_bad,
      app_wdf_data => wd_bad, app_wdf_mask => wm_bad, app_wdf_wren => wr_bad,
      app_wdf_end => we_bad, app_wdf_rdy => wready_bad,
      app_rd_data => rd_bad_corrupt, app_rd_data_valid => rv_bad, app_rd_data_end => re_bad,
      led => led_bad, seg => seg_bad, an => an_bad, dp => dp_bad);

  -- The bad instance is intentionally fed one flipped read-data bit, guaranteeing failure.
  process
  begin
    wait for 50 ns;
    rst <= '0';
    wait until led_ok(1) = '1' and led_bad(2) = '1';
    assert led_ok(0) = '1' and led_bad(0) = '1'
      report "memtest did not indicate calibration complete" severity failure;
    assert led_ok(2) = '0' and led_bad(1) = '0'
      report "memtest pass/fail LEDs are inconsistent" severity failure;
    report "PASS: memtest pass path and deliberately corrupted read fail path" severity note;
    std.env.stop;
    wait;
  end process;
end architecture;

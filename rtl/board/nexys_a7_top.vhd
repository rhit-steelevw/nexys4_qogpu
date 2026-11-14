-- nexys_a7_top.vhd : Nexys A7-100T board wrapper around gpu_top (RQ-103)
--
-- Port names match Digilent's Nexys-A7-100T-Master.xdc so the XDC lines can be
-- copied as they are. Board policy lives here, not in gpu_top:
--   * CPU_RESETN (active low) -> gpu_top rst_n (gpu_top synchronizes it)
--   * BTNC: 2-flop sync, ~10 ms debounce, rising edge -> start pulse (redraw)
--   * auto-start: one start pulse ~1 ms after reset release
--   * RGB332 -> 4-4-4 by replicating top bits (7 -> 15, 3 -> 15, black stays 0)
--   * LED0 heartbeat ~1 Hz, LED1 busy, LED2 frame done (sticky), LED3 error
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity nexys_a7_top is
  port (
    CLK100MHZ  : in  std_logic;
    CPU_RESETN : in  std_logic;
    BTNC       : in  std_logic;
    VGA_R      : out std_logic_vector(3 downto 0);
    VGA_G      : out std_logic_vector(3 downto 0);
    VGA_B      : out std_logic_vector(3 downto 0);
    VGA_HS     : out std_logic;
    VGA_VS     : out std_logic;
    LED        : out std_logic_vector(3 downto 0)
  );
end entity;

architecture rtl of nexys_a7_top is
  constant CLK_HZ        : natural := 100_000_000;
  constant DEBOUNCE_CLKS : natural := CLK_HZ / 100;    -- 10 ms
  constant AUTOSTART_CLKS: natural := CLK_HZ / 1000;   -- 1 ms

  signal r3, g3 : std_logic_vector(2 downto 0);
  signal b2     : std_logic_vector(1 downto 0);
  signal start  : std_logic := '0';
  signal busy, frame_done, err : std_logic;

  signal btn_meta, btn_sync, btn_stable, btn_prev : std_logic := '0';
  signal deb_cnt  : natural range 0 to DEBOUNCE_CLKS := 0;
  signal auto_cnt : natural range 0 to AUTOSTART_CLKS := 0;
  signal hb_cnt   : unsigned(26 downto 0) := (others => '0');
  signal rst_meta, rst_sync : std_logic := '0';
  signal auto_done : std_logic := '0';
begin
  u_gpu : entity work.gpu_top
    port map (
      clk => CLK100MHZ, rst_n => CPU_RESETN, start_i => start,
      vga_r => r3, vga_g => g3, vga_b => b2,
      vga_hs_n => VGA_HS, vga_vs_n => VGA_VS,     -- 640x480 syncs are active low
      busy_o => busy, frame_done_o => frame_done, error_o => err
    );

  -- RGB332 -> 4-4-4 (wiring only; gpu_top's RGB already leaves from registers)
  VGA_R <= r3 & r3(2);
  VGA_G <= g3 & g3(2);
  VGA_B <= b2 & b2;

  process (CLK100MHZ)
  begin
    if rising_edge(CLK100MHZ) then
      start <= '0';
      btn_meta <= BTNC;
      btn_sync <= btn_meta;

      if btn_sync = btn_stable then
        deb_cnt <= 0;
      elsif deb_cnt = DEBOUNCE_CLKS then
        btn_stable <= btn_sync;
        deb_cnt    <= 0;
      else
        deb_cnt <= deb_cnt + 1;
      end if;

      btn_prev <= btn_stable;
      if btn_stable = '1' and btn_prev = '0' then
        start <= '1';
      end if;

      rst_meta <= CPU_RESETN;
      rst_sync <= rst_meta;
      if rst_sync = '0' then
        auto_cnt  <= 0;
        auto_done <= '0';
      elsif auto_done = '0' then
        if auto_cnt = AUTOSTART_CLKS then
          start     <= '1';
          auto_done <= '1';
        else
          auto_cnt <= auto_cnt + 1;
        end if;
      end if;

      hb_cnt <= hb_cnt + 1;
    end if;
  end process;

  LED(0) <= hb_cnt(hb_cnt'high);     -- ~0.75 Hz at 100 MHz
  LED(1) <= busy;
  LED(2) <= frame_done;
  LED(3) <= err;
end architecture;

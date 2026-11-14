-- Self-checking native-UI model test. Includes independent handshakes,
-- byte masking, random stalls/latency, and 10,000 accepted UI transactions.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mig_ui_model_tb is end entity;

architecture test of mig_ui_model_tb is
  constant ADDR_W : positive := 27;
  constant DATA_W : positive := 64;
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal calib : std_logic;
  signal addr : std_logic_vector(ADDR_W-1 downto 0) := (others => '0');
  signal cmd : std_logic_vector(2 downto 0) := "000";
  signal en, rdy : std_logic := '0';
  signal wdata : std_logic_vector(DATA_W-1 downto 0) := (others => '0');
  signal wmask : std_logic_vector(DATA_W/8-1 downto 0) := (others => '0');
  signal wren, wend, wready : std_logic := '0';
  signal rdata : std_logic_vector(DATA_W-1 downto 0);
  signal rvalid, rend : std_logic;
  constant CLK_PERIOD : time := 10 ns;

  function test_pattern(n : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(n, 64) xor x"A5C39E7101234567");
  end function;
begin
  clk <= not clk after CLK_PERIOD/2;

  dut : entity work.mig_ui_model
    generic map (ADDR_W => ADDR_W, DATA_W => DATA_W, MEM_WORDS => 8192,
                 RD_LAT_MIN => 10, RD_LAT_MAX => 40, STALL_PCT => 5, SEED => 16#1234#)
    port map (ui_clk => clk, ui_rst => rst, init_calib_complete => calib,
      app_addr => addr, app_cmd => cmd, app_en => en, app_rdy => rdy,
      app_wdf_data => wdata, app_wdf_mask => wmask, app_wdf_wren => wren,
      app_wdf_end => wend, app_wdf_rdy => wready,
      app_rd_data => rdata, app_rd_data_valid => rvalid, app_rd_data_end => rend);

  stimulus : process
    procedure write_beat(a : natural; d : std_logic_vector(63 downto 0);
                         m : std_logic_vector(7 downto 0)) is
      variable cmd_ok, data_ok : boolean := false;
      variable watchdog : natural := 0;
    begin
      addr <= std_logic_vector(to_unsigned(a*8, ADDR_W));
      cmd <= "000"; en <= '1';
      wdata <= d; wmask <= m; wren <= '1'; wend <= '1';
      while not (cmd_ok and data_ok) loop
        wait until rising_edge(clk);
        if not cmd_ok and rdy = '1' then cmd_ok := true; end if;
        if not data_ok and wready = '1' then data_ok := true; end if;
        watchdog := watchdog + 1;
        assert watchdog < 500 report "write handshake watchdog expired" severity failure;
      end loop;
      en <= '0'; wren <= '0';
      wait until rising_edge(clk);
    end procedure;

    procedure read_beat(a : natural; expected : std_logic_vector(63 downto 0)) is
      variable accepted : boolean := false;
      variable watchdog : natural := 0;
    begin
      addr <= std_logic_vector(to_unsigned(a*8, ADDR_W));
      cmd <= "001"; en <= '1';
      while not accepted loop
        wait until rising_edge(clk);
        if rdy = '1' then accepted := true; end if;
        watchdog := watchdog + 1;
        assert watchdog < 500 report "read command watchdog expired" severity failure;
      end loop;
      en <= '0';
      watchdog := 0;
      loop
        wait until rising_edge(clk);
        exit when rvalid = '1';
        watchdog := watchdog + 1;
        assert watchdog < 500 report "read response watchdog expired" severity failure;
      end loop;
      assert rend = '1' report "app_rd_data_end missing" severity failure;
      assert rdata = expected
        report "readback mismatch at UI beat " & integer'image(a) severity failure;
    end procedure;

    variable expected : std_logic_vector(63 downto 0);
  begin
    wait for 5*CLK_PERIOD;
    wait until rising_edge(clk); rst <= '0';
    wait until calib = '1';

    -- Basic write/read and byte-mask check (mask bit 1 means suppress byte).
    write_beat(0, x"0123456789ABCDEF", x"00");
    read_beat(0, x"0123456789ABCDEF");
    write_beat(0, x"FFFFFFFFFFFFFFFF", x"01");
    read_beat(0, x"FFFFFFFFFFFFFFEF");

    -- 5,000 writes + 5,000 reads = 10,000 accepted UI transactions.
    for i in 1 to 5000 loop
      expected := test_pattern(i);
      write_beat(i, expected, x"00");
      read_beat(i, expected);
    end loop;

    report "PASS: MIG UI model completed masked-write test and 10,000 transactions" severity note;
    std.env.stop;
    wait;
  end process;
end architecture;

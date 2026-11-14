-- UI-side memory test engine for the Nexys A7 MIG native interface.
-- The board wrapper must connect these UI ports to the generated MIG instance.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ddr2_memtest is
  generic (
    ADDR_W : positive := 27;
    DATA_W : positive := 64;
    TEST_BYTES : positive := 131072
  );
  port (
    ui_clk : in std_logic;
    ui_rst : in std_logic;
    init_calib_complete : in std_logic;
    app_addr : out std_logic_vector(ADDR_W-1 downto 0);
    app_cmd : out std_logic_vector(2 downto 0);
    app_en : out std_logic;
    app_rdy : in std_logic;
    app_wdf_data : out std_logic_vector(DATA_W-1 downto 0);
    app_wdf_mask : out std_logic_vector(DATA_W/8-1 downto 0);
    app_wdf_wren : out std_logic;
    app_wdf_end : out std_logic;
    app_wdf_rdy : in std_logic;
    app_rd_data : in std_logic_vector(DATA_W-1 downto 0);
    app_rd_data_valid : in std_logic;
    app_rd_data_end : in std_logic;
    led : out std_logic_vector(2 downto 0);
    seg : out std_logic_vector(6 downto 0);
    an : out std_logic_vector(3 downto 0);
    dp : out std_logic
  );
end entity;

architecture rtl of ddr2_memtest is
  constant BYTE_W : positive := DATA_W/8;
  constant TEST_BEATS : positive := TEST_BYTES/BYTE_W;
  type state_t is (WAIT_CAL, WRITE_BEAT, READ_CMD, READ_WAIT, PASSED, FAILED);
  signal state : state_t := WAIT_CAL;
  signal beat : natural range 0 to TEST_BEATS-1 := 0;
  signal cmd_done, data_done : std_logic := '0';
  signal error_count : unsigned(15 downto 0) := (others => '0');
  signal mismatch : std_logic := '0';
  signal scan_div : unsigned(15 downto 0) := (others => '0');
  signal digit : unsigned(1 downto 0) := (others => '0');
  signal hex_value : std_logic_vector(3 downto 0);

  function make_pattern(a : natural) return std_logic_vector is
    variable x : unsigned(DATA_W-1 downto 0);
  begin
    x := shift_left(to_unsigned(a, DATA_W), 17) xor to_unsigned(16#A5C39E71#, DATA_W);
    x := x xor shift_left(to_unsigned(a, DATA_W), 3);
    return std_logic_vector(x);
  end function;

  function hex_to_seg(v : std_logic_vector(3 downto 0)) return std_logic_vector is
  begin
    -- Active-low segments, order abcdefg.
    case v is
      when "0000" => return "0000001"; when "0001" => return "1001111";
      when "0010" => return "0010010"; when "0011" => return "0000110";
      when "0100" => return "1001100"; when "0101" => return "0100100";
      when "0110" => return "0100000"; when "0111" => return "0001111";
      when "1000" => return "0000000"; when "1001" => return "0000100";
      when "1010" => return "0001000"; when "1011" => return "1100000";
      when "1100" => return "0110001"; when "1101" => return "1000010";
      when "1110" => return "0110000"; when others => return "0111000";
    end case;
  end function;
begin
  assert DATA_W >= 8 and DATA_W mod 8 = 0
    report "ddr2_memtest: DATA_W must be a multiple of 8" severity failure;
  assert TEST_BYTES mod BYTE_W = 0
    report "ddr2_memtest: TEST_BYTES must be divisible by bytes per UI beat" severity failure;
  assert TEST_BEATS <= 2**ADDR_W / BYTE_W
    report "ddr2_memtest: test region does not fit in app_addr" severity failure;

  app_addr <= std_logic_vector(to_unsigned(beat*BYTE_W, ADDR_W));
  app_cmd <= "000" when state = WRITE_BEAT else "001";
  app_en <= '1' when (state = WRITE_BEAT and cmd_done = '0') or state = READ_CMD else '0';
  app_wdf_data <= make_pattern(beat);
  app_wdf_mask <= (others => '0');
  app_wdf_wren <= '1' when state = WRITE_BEAT and data_done = '0' else '0';
  app_wdf_end <= '1';

  led(0) <= init_calib_complete;
  led(1) <= '1' when state = PASSED else '0';
  led(2) <= '1' when state = FAILED else '0';
  dp <= '1';

  process(ui_clk)
  begin
    if rising_edge(ui_clk) then
      if ui_rst = '1' then
        state <= WAIT_CAL;
        beat <= 0;
        cmd_done <= '0';
        data_done <= '0';
        error_count <= (others => '0');
        mismatch <= '0';
      else
        case state is
          when WAIT_CAL =>
            if init_calib_complete = '1' then state <= WRITE_BEAT; end if;
          when WRITE_BEAT =>
            if app_en = '1' and app_rdy = '1' then cmd_done <= '1'; end if;
            if app_wdf_wren = '1' and app_wdf_rdy = '1' then data_done <= '1'; end if;
            if (cmd_done = '1' or (app_en = '1' and app_rdy = '1')) and
               (data_done = '1' or (app_wdf_wren = '1' and app_wdf_rdy = '1')) then
              cmd_done <= '0';
              data_done <= '0';
              if beat = TEST_BEATS-1 then
                beat <= 0;
                state <= READ_CMD;
              else
                beat <= beat + 1;
              end if;
            end if;
          when READ_CMD =>
            if app_en = '1' and app_rdy = '1' then state <= READ_WAIT; end if;
          when READ_WAIT =>
            if app_rd_data_valid = '1' then
              if app_rd_data_end /= '1' or app_rd_data /= make_pattern(beat) then
                mismatch <= '1';
                if error_count /= x"FFFF" then error_count <= error_count + 1; end if;
              end if;
              if beat = TEST_BEATS-1 then
                if error_count = 0 and mismatch = '0' and
                   app_rd_data_end = '1' and app_rd_data = make_pattern(beat) then
                  state <= PASSED;
                else
                  state <= FAILED;
                end if;
              else
                beat <= beat + 1;
                state <= READ_CMD;
              end if;
            end if;
          when PASSED => null;
          when FAILED => null;
        end case;
      end if;
    end if;
  end process;

  -- Four-digit multiplexed display: least-significant four hex digits of error_count.
  process(ui_clk)
  begin
    if rising_edge(ui_clk) then
      if ui_rst = '1' then scan_div <= (others => '0'); digit <= (others => '0');
      else
        scan_div <= scan_div + 1;
        if scan_div = 0 then digit <= digit + 1; end if;
      end if;
    end if;
  end process;

  with digit select hex_value <=
    std_logic_vector(error_count(3 downto 0)) when "00",
    std_logic_vector(error_count(7 downto 4)) when "01",
    std_logic_vector(error_count(11 downto 8)) when "10",
    std_logic_vector(error_count(15 downto 12)) when others;
  seg <= hex_to_seg(hex_value);
  with digit select an <= "1110" when "00", "1101" when "01", "1011" when "10", "0111" when others;
end architecture;

-- Fast behavioral model of the 7-series MIG native user interface.
-- VHDL-2008. This is a UI model only; it does not model DDR2 pins or analog timing.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mig_ui_model is
  generic (
    ADDR_W    : positive := 27;
    DATA_W    : positive := 64;
    MEM_WORDS : positive := 65536;
    RD_LAT_MIN : positive := 10;
    RD_LAT_MAX : positive := 40;
    STALL_PCT  : natural range 0 to 99 := 5;
    SEED       : positive := 1
  );
  port (
    ui_clk : in std_logic;
    ui_rst : in std_logic;
    init_calib_complete : out std_logic;

    app_addr : in std_logic_vector(ADDR_W-1 downto 0);
    app_cmd  : in std_logic_vector(2 downto 0);
    app_en   : in std_logic;
    app_rdy  : out std_logic;

    app_wdf_data : in std_logic_vector(DATA_W-1 downto 0);
    app_wdf_mask : in std_logic_vector(DATA_W/8-1 downto 0);
    app_wdf_wren : in std_logic;
    app_wdf_end  : in std_logic;
    app_wdf_rdy  : out std_logic;

    app_rd_data       : out std_logic_vector(DATA_W-1 downto 0);
    app_rd_data_valid : out std_logic;
    app_rd_data_end   : out std_logic
  );
end entity;

architecture behavioral of mig_ui_model is
  constant BYTE_W : positive := DATA_W / 8;
  function clog2(n : positive) return natural is
    variable v : natural := n - 1;
    variable r : natural := 0;
  begin
    while v > 0 loop v := v / 2; r := r + 1; end loop;
    return r;
  end function;
  constant BYTE_SHIFT : natural := clog2(BYTE_W);
  type memory_t is array (0 to MEM_WORDS-1) of std_logic_vector(DATA_W-1 downto 0);
  signal memory : memory_t := (others => (others => '0'));
  signal lfsr : unsigned(31 downto 0) := to_unsigned(SEED, 32);
  signal calib_count : natural range 0 to 32 := 0;
  signal calibrated : std_logic := '0';

  signal write_cmd_pending : std_logic := '0';
  signal write_data_pending : std_logic := '0';
  signal pending_addr : std_logic_vector(ADDR_W-1 downto 0) := (others => '0');
  signal pending_data : std_logic_vector(DATA_W-1 downto 0) := (others => '0');
  signal pending_mask : std_logic_vector(BYTE_W-1 downto 0) := (others => '1');

  signal read_pending : std_logic := '0';
  signal read_count : natural range 0 to RD_LAT_MAX := 0;
  signal read_data_reg : std_logic_vector(DATA_W-1 downto 0) := (others => '0');
  signal rd_valid_reg : std_logic := '0';

  function addr_index(a : std_logic_vector) return natural is
    variable shifted : unsigned(a'length-BYTE_SHIFT-1 downto 0);
  begin
    shifted := unsigned(a(a'length-1 downto BYTE_SHIFT));
    if shifted > to_unsigned(MEM_WORDS-1, shifted'length) then
      return MEM_WORDS;
    end if;
    return to_integer(shifted);
  end function;

  function lfsr_next(x : unsigned(31 downto 0)) return unsigned is
    variable y : unsigned(31 downto 0) := x;
  begin
    y := y xor shift_left(y, 13);
    y := y xor shift_right(y, 17);
    y := y xor shift_left(y, 5);
    if y = 0 then y := to_unsigned(1, 32); end if;
    return y;
  end function;

  function random_latency(x : unsigned(31 downto 0)) return natural is
  begin
    return RD_LAT_MIN + (to_integer(x(23 downto 8)) mod (RD_LAT_MAX-RD_LAT_MIN+1));
  end function;
begin
  assert DATA_W >= 8 and DATA_W mod 8 = 0
    report "mig_ui_model: DATA_W must be a positive multiple of 8" severity failure;
  assert 2**BYTE_SHIFT = BYTE_W
    report "mig_ui_model: bytes per UI beat must be a power of two" severity failure;
  assert RD_LAT_MAX >= RD_LAT_MIN
    report "mig_ui_model: RD_LAT_MAX must be >= RD_LAT_MIN" severity failure;

  init_calib_complete <= calibrated;
  app_rd_data <= read_data_reg;
  app_rd_data_valid <= rd_valid_reg;
  app_rd_data_end <= rd_valid_reg;

  -- Independent command and write-data channels can be accepted on different cycles.
  app_rdy <= '1' when calibrated = '1' and write_cmd_pending = '0'
             and read_pending = '0'
             and (to_integer(lfsr(7 downto 0)) mod 100) >= STALL_PCT else '0';
  app_wdf_rdy <= '1' when calibrated = '1' and write_data_pending = '0'
                 and (to_integer(lfsr(15 downto 8)) mod 100) >= STALL_PCT else '0';

  process(ui_clk)
    variable cmd_take, data_take : boolean;
    variable cmd_addr_v : std_logic_vector(ADDR_W-1 downto 0);
    variable data_v : std_logic_vector(DATA_W-1 downto 0);
    variable mask_v : std_logic_vector(BYTE_W-1 downto 0);
    variable idx : natural;
    variable merged : std_logic_vector(DATA_W-1 downto 0);
    variable lat : natural;
  begin
    if rising_edge(ui_clk) then
      if ui_rst = '1' then
        lfsr <= to_unsigned(SEED, 32);
        calib_count <= 0;
        calibrated <= '0';
        write_cmd_pending <= '0';
        write_data_pending <= '0';
        read_pending <= '0';
        read_count <= 0;
        read_data_reg <= (others => '0');
        rd_valid_reg <= '0';
      else
        lfsr <= lfsr_next(lfsr);
        rd_valid_reg <= '0';
        if calibrated = '0' then
          if calib_count = 31 then
            calib_count <= 32;
            calibrated <= '1';
          else
            calib_count <= calib_count + 1;
          end if;
        end if;

        -- Complete a scheduled read after its configured UI-clock latency.
        if read_pending = '1' then
          if read_count <= 1 then
            rd_valid_reg <= '1';
            read_pending <= '0';
            read_count <= 0;
          else
            read_count <= read_count - 1;
          end if;
        end if;

        cmd_take := app_en = '1' and app_rdy = '1';
        data_take := app_wdf_wren = '1' and app_wdf_rdy = '1';
        cmd_addr_v := pending_addr;
        data_v := pending_data;
        mask_v := pending_mask;

        if cmd_take then
          if app_cmd = "001" then
            assert write_data_pending = '0' and write_cmd_pending = '0'
              report "mig_ui_model: read command while an unmatched write-data beat is pending" severity failure;
            idx := addr_index(app_addr);
            if idx < MEM_WORDS then
              read_data_reg <= memory(idx);
            else
              read_data_reg <= (others => '0');
              assert false report "mig_ui_model: read address exceeds modeled memory" severity warning;
            end if;
            lat := random_latency(lfsr);
            read_count <= lat;
            read_pending <= '1';
          elsif app_cmd = "000" then
            cmd_addr_v := app_addr;
            write_cmd_pending <= '1';
          else
            assert false report "mig_ui_model: unsupported app_cmd (expected 000=write or 001=read)" severity failure;
          end if;
        end if;

        if data_take then
          assert app_wdf_end = '1'
            report "mig_ui_model: this model expects one complete UI data beat per write" severity failure;
          data_v := app_wdf_data;
          mask_v := app_wdf_mask;
          write_data_pending <= '1';
        end if;

        if write_cmd_pending = '1' or cmd_take and app_cmd = "000" then
          if write_data_pending = '1' or data_take then
            idx := addr_index(cmd_addr_v);
            if idx < MEM_WORDS then
              merged := memory(idx);
              for b in 0 to BYTE_W-1 loop
                if mask_v(b) = '0' then
                  merged(8*b+7 downto 8*b) := data_v(8*b+7 downto 8*b);
                end if;
              end loop;
              memory(idx) <= merged;
            else
              assert false report "mig_ui_model: write address exceeds modeled memory" severity warning;
            end if;
            write_cmd_pending <= '0';
            write_data_pending <= '0';
          elsif cmd_take then
            pending_addr <= cmd_addr_v;
          end if;
        end if;

        if data_take and not (write_cmd_pending = '1' or cmd_take and app_cmd = "000") then
          pending_data <= data_v;
          pending_mask <= mask_v;
        end if;
        if cmd_take and app_cmd = "000" and not (write_data_pending = '1' or data_take) then
          pending_addr <= app_addr;
        end if;
      end if;
    end if;
  end process;
end architecture;

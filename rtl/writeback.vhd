-- E6 write-back: color -> BRAM framebuffer, depth -> memory controller.
-- One fragment in flight. Accepts when idle; fb_we pulses for one cycle,
-- mem_req_valid is held until the controller accepts (mem_req_ready).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity writeback is
  generic (DEPTH_W : natural := 8);
  port (
    clk, rst_n : in std_logic;
    pass_valid : in std_logic; pass_ready : out std_logic;
    pass_x : in unsigned(8 downto 0); pass_y : in unsigned(7 downto 0);
    pass_z : in unsigned(DEPTH_W-1 downto 0); pass_color : in std_logic_vector(7 downto 0);
    fb_we : out std_logic; fb_waddr : out unsigned(16 downto 0); fb_wdata : out std_logic_vector(7 downto 0);
    mem_req_valid : out std_logic; mem_req_ready : in std_logic; mem_req_we : out std_logic;
    mem_req_addr : out unsigned(16 downto 0); mem_req_wdata : out std_logic_vector(DEPTH_W-1 downto 0)
  );
end entity;

architecture rtl of writeback is
  signal busy    : std_logic := '0';
  signal fb_we_r : std_logic := '0';
  signal req_v_r : std_logic := '0';
  signal addr_r  : unsigned(16 downto 0) := (others => '0');
  signal addr_in : unsigned(16 downto 0);
begin
  -- y*320 + x; max 239*320+319 = 76799 < 2**17
  addr_in <= resize(pass_y * to_unsigned(320, 9), 17) + resize(pass_x, 17);

  -- upstream (E4) must clip to 320x240; this only flags a violation in simulation
  assert not (busy = '0' and pass_valid = '1' and addr_in >= 76800)
    report "writeback: fragment outside 320x240" severity error;

  pass_ready    <= not busy;
  fb_we         <= fb_we_r;
  fb_waddr      <= addr_r;
  mem_req_valid <= req_v_r;
  mem_req_we    <= '1';
  mem_req_addr  <= addr_r;   -- shortcut: depth address == pixel address (one word per pixel), confirm with N1

  process (clk)
  begin
    if rising_edge(clk) then
      if rst_n = '0' then
        busy <= '0'; fb_we_r <= '0'; req_v_r <= '0';
      else
        fb_we_r <= '0';
        if busy = '0' then
          if pass_valid = '1' then
            addr_r        <= addr_in;
            fb_wdata      <= pass_color;
            mem_req_wdata <= std_logic_vector(pass_z);
            fb_we_r       <= '1';
            req_v_r       <= '1';
            busy          <= '1';
          end if;
        elsif mem_req_ready = '1' then  -- req_v_r is '1' while busy
          req_v_r <= '0';
          busy    <= '0';
        end if;
      end if;
    end if;
  end process;
end architecture;

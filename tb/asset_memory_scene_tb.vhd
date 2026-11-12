library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity asset_memory_scene_tb is
end entity asset_memory_scene_tb;

architecture sim of asset_memory_scene_tb is
    constant CLK_PERIOD : time := 10 ns;

    signal clk  : std_logic := '0';
    signal addr : unsigned(9 downto 0) := (others => '0');
    signal data : std_logic_vector(31 downto 0);

    type word_array_t is array (0 to 1023) of
        std_logic_vector(31 downto 0);

    constant EXPECTED : word_array_t := (
        -- Vertex A
        0 => x"FFFF4000", 1 => x"00008000", 2 => x"FFFF8000",
        -- Vertex B
        6 => x"00004000", 7 => x"00008000", 8 => x"FFFF8000",
        -- Vertex C
        12 => x"FFFFC000", 13 => x"FFFF4000", 14 => x"FFFF8000",
        -- Vertex D
        18 => x"FFFFC000", 19 => x"0000C000", 20 => x"00008000",
        -- Vertex E
        24 => x"0000C000", 25 => x"0000C000", 26 => x"00008000",
        -- Vertex F
        30 => x"00004000", 31 => x"FFFF8000", 32 => x"00008000",
        -- Face indices
        144 => x"00000001", 145 => x"00000002", 146 => x"00000003",
        147 => x"00000004", 148 => x"00000005", 149 => x"00000006",
        others => x"00000000"
    );

begin
    clk <= not clk after CLK_PERIOD / 2;

    dut : entity work.asset_memory
        generic map (
            INIT_FILE => "scenes/scene_two_triangles.mem"
        )
        port map (
            clk  => clk,
            addr => addr,
            data => data
        );

    stim : process
    begin
        for address in EXPECTED'range loop
            addr <= to_unsigned(address, addr'length);
            wait until rising_edge(clk);
            wait for 1 ns;

            assert data = EXPECTED(address)
                report "FAIL at word " & integer'image(address)
                    & ": expected " & to_hstring(EXPECTED(address))
                    & ", got " & to_hstring(data)
                severity failure;
        end loop;

        report "PASS: asset_memory loaded and read all 1024 fixture words";
        finish;
        wait;
    end process stim;
end architecture sim;
with NEORV32_System;
with NEORV32_UART;
with Usart_Interface;

package Instances is

   --  Console: UART0, wired in the gateware to the USB-UART bridge (FT2232HQ
   --  channel B, the board's serial port).
   package UART_0 is new NEORV32_UART (Port => NEORV32_System.UART0);

   package Console is new Usart_Interface
     (Driver_Init    => UART_0.Init,
      Driver_Enable  => UART_0.Enable,
      Driver_Disable => UART_0.Disable,
      Driver_Reset   => UART_0.Reset,
      Driver_Tx_Push => UART_0.Tx_Push,
      Driver_Rx_Pop  => UART_0.Rx_Pop);

end Instances;

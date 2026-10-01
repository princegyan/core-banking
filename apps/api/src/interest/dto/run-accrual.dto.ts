import { IsDateString, IsEnum, IsNotEmpty } from 'class-validator';

export class RunAccrualDto {
  @IsDateString()
  @IsNotEmpty()
  accrualDate: string;

  @IsEnum(['DEPOSIT', 'LOAN'])
  @IsNotEmpty()
  accountType: 'DEPOSIT' | 'LOAN';
}

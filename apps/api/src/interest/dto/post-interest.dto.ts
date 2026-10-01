import { IsDateString, IsEnum, IsNotEmpty } from 'class-validator';

export class PostInterestDto {
  @IsDateString()
  @IsNotEmpty()
  postingDate: string;

  @IsEnum(['DEPOSIT', 'LOAN'])
  @IsNotEmpty()
  accountType: 'DEPOSIT' | 'LOAN';
}

import {
  IsEnum,
  IsInt,
  IsNotEmpty,
  IsString,
  MaxLength,
  Min,
} from 'class-validator';

export enum LimitType {
  DAILY_TRANSACTION = 'DAILY_TRANSACTION',
  SINGLE_TRANSACTION = 'SINGLE_TRANSACTION',
  DAILY_APPROVAL = 'DAILY_APPROVAL',
  DAILY_CASH_WITHDRAWAL = 'DAILY_CASH_WITHDRAWAL',
  DAILY_CASH_DEPOSIT = 'DAILY_CASH_DEPOSIT',
  DAILY_TRANSFER = 'DAILY_TRANSFER',
}

export class SetUserLimitDto {
  @IsEnum(LimitType)
  limitType: LimitType;

  @IsInt()
  @Min(0)
  maxAmount: number;

  @IsString()
  @IsNotEmpty()
  @MaxLength(3)
  currency: string;
}

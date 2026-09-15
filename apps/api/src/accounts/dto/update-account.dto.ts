import {
  IsEnum,
  IsOptional,
} from 'class-validator';

export enum AccountStatus {
  ACTIVE = 'ACTIVE',
  FROZEN = 'FROZEN',
  DORMANT = 'DORMANT',
  CLOSED = 'CLOSED',
}

export class UpdateAccountDto {
  @IsOptional()
  @IsEnum(AccountStatus)
  status?: AccountStatus;
}
